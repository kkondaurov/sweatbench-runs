defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  @booked_on "2026-10-03"
  @arrival_on "2026-12-10"
  # Refundable for a flex-14 group booked 2026-10-03 arriving 2026-12-10.
  @refundable_on "2026-11-26"

  describe "transfer_deposit" do
    test "moves held cash between groups in reverse allocation order", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 12_000)])

      # op-pay holds 9_000 on room-a and 3_000 on room-b; the draw takes the
      # room-b allocation first, then part of room-a's
      result =
        only_result(submit(conn, [transfer_op("op-transfer", "group-src", "group-dst", 5_000)]))

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-src",
               "destination_group_id" => "group-dst",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 12_500,
               "destination_outstanding_deposit_cents" => 14_500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = get_group(conn, "group-src")
      destination = get_group(conn, "group-dst")

      assert Enum.map(source["rooms"], & &1["cash_paid_cents"]) == [7_000, 0]
      assert source["deposit_paid_cents"] == 7_000

      # the destination fills its first room before moving to the next
      assert Enum.map(destination["rooms"], & &1["cash_paid_cents"]) == [5_000, 0]
      assert destination["deposit_paid_cents"] == 5_000
    end

    test "a transfer moves no money through the ledger", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 8_000)])

      before = ledger(conn)

      assert only_result(submit(conn, [transfer_op("op-t", "group-src", "group-dst", 3_000)]))[
               "status"
             ] == "applied"

      assert ledger(conn) == before
    end

    test "moved cash keeps its payment identity and settles under the destination policy", %{
      conn: conn
    } do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 6_000)])
      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 4_000)])

      # the transferred cash converts with the standard bonus at the
      # destination's own refundable cancellation
      result =
        only_result(submit(conn, [credit_cancel_op("op-cancel", "group-dst", @refundable_on)]))

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 4_400

      assert ledger(conn)["cash_converted_to_credit_cents"] == 4_000

      # the untouched remainder at the source is unaffected
      assert get_group(conn, "group-src")["cash_paid_cents"] == 2_000
    end

    test "moved hotel credit keeps its lot and original expiry", %{conn: conn} do
      issue_credit(conn, "op-issue", "group-lot", 10_000, "2026-11-01")
      open_pair!(conn)

      submit(conn, [payment_op("op-pay", "group-src", 4_000)])
      submit(conn, [credit_op("op-credit", "group-src", 2_000)])

      # held allocations newest first: the credit allocation moves entirely,
      # then part of the cash
      result =
        only_result(submit(conn, [transfer_op("op-t", "group-src", "group-dst", 5_000)]))

      assert result["status"] == "applied"

      destination = get_group(conn, "group-dst")

      assert Enum.map(destination["rooms"], fn room ->
               {room["cash_paid_cents"], room["credit_paid_cents"]}
             end) == [{3_000, 2_000}, {0, 0}]

      # the transferred credit stays applied with expiry paused: it is not
      # available and did not gain a second bonus
      assert guest_credit(conn, "guest-22")["available_cents"] == 9_000

      # a refundable destination settlement restores it to its original lot
      submit(conn, [cancel_op("op-cancel-dst", "group-dst", @refundable_on)])

      credit = guest_credit(conn, "guest-22", on: "2027-11-01")

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-issue",
                 "remaining_cents" => 11_000,
                 "expires_on" => "2027-11-02"
               }
             ]

      # only the cash was refunded
      assert ledger(conn)["cash_refunded_cents"] == 3_000
    end

    test "increments both group revisions exactly once and rejections never", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])

      assert rejection(
               submit(conn, [transfer_op("op-bad", "group-src", "group-dst", 999_999)]),
               "transfer_exceeds_held_funding"
             )

      assert get_group(conn, "group-src")["revision"] == 2
      assert get_group(conn, "group-dst")["revision"] == 1

      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 1_000)])

      assert get_group(conn, "group-src")["revision"] == 3
      assert get_group(conn, "group-dst")["revision"] == 2
    end

    test "rejects missing groups with that group's identifier", %{conn: conn} do
      open_pair!(conn)

      result =
        only_result(submit(conn, [transfer_op("op-t", "nowhere", "group-dst", 100)]))

      assert result == %{
               "operation_id" => "op-t",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nowhere"
             }

      result =
        only_result(submit(conn, [transfer_op("op-t2", "group-src", "nowhere", 100)]))

      assert result == %{
               "operation_id" => "op-t2",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nowhere"
             }
    end

    test "rejects the same group or different guests with invalid_transfer", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [open_op("group-other", guest_id: "guest-99")])

      assert rejection(
               submit(conn, [transfer_op("op-same", "group-src", "group-src", 100)]),
               "invalid_transfer"
             )

      assert rejection(
               submit(conn, [transfer_op("op-guest", "group-src", "group-other", 100)]),
               "invalid_transfer"
             )
    end

    test "rejects an inactive group with that group's identifier", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [cancel_op("op-cancel", "group-src", @refundable_on)])

      result = only_result(submit(conn, [transfer_op("op-t", "group-src", "group-dst", 100)]))

      assert result == %{
               "operation_id" => "op-t",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-src"
             }

      submit(conn, [open_op("group-dead", rate_plan: "advance_purchase")])
      submit(conn, [cancel_op("op-cancel-2", "group-dead", "2026-10-05")])

      result =
        only_result(submit(conn, [transfer_op("op-t2", "group-dst", "group-dead", 100)]))

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-dead"
    end

    test "rejects unusable amounts", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])

      for {amount, index} <- Enum.with_index([0, -100, "100", nil]) do
        assert rejection(
                 submit(conn, [transfer_op("op-bad-#{index}", "group-src", "group-dst", amount)]),
                 "invalid_amount"
               )
      end
    end

    test "rejects amounts above the held funding or the outstanding deposit", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])

      assert rejection(
               submit(conn, [transfer_op("op-held", "group-src", "group-dst", 5_001)]),
               "transfer_exceeds_held_funding"
             )

      submit(conn, [payment_op("op-fill", "group-dst", 19_000)])

      assert rejection(
               submit(conn, [transfer_op("op-outstanding", "group-src", "group-dst", 1_000)]),
               "transfer_exceeds_outstanding"
             )
    end

    test "checks the source revision then the destination revision", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])

      result =
        only_result(
          submit(conn, [
            transfer_op("op-stale-source", "group-src", "group-dst", 100)
            |> Map.put("expected_revision", 99)
          ])
        )

      assert result == %{
               "operation_id" => "op-stale-source",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-src",
               "expected_revision" => 99,
               "actual_revision" => 2
             }

      result =
        only_result(
          submit(conn, [
            transfer_op("op-stale-dest", "group-src", "group-dst", 100)
            |> Map.put("expected_revision", 2)
            |> Map.put("destination_expected_revision", 42)
          ])
        )

      assert result == %{
               "operation_id" => "op-stale-dest",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-dst",
               "expected_revision" => 42,
               "actual_revision" => 1
             }

      current =
        transfer_op("op-current", "group-src", "group-dst", 100)
        |> Map.put("expected_revision", 2)
        |> Map.put("destination_expected_revision", 1)

      assert only_result(submit(conn, [current]))["status"] == "applied"
    end

    test "revision checks precede the transfer rules", %{conn: conn} do
      open_pair!(conn)

      # the source holds nothing, so the amount rule would also fail; the
      # stale revision is reported instead because it is checked first
      assert rejection(
               submit(conn, [
                 transfer_op("op-precedence", "group-src", "group-dst", 100)
                 |> Map.put("expected_revision", 99)
               ]),
               "stale_revision"
             )
    end

    test "is durably idempotent", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 8_000)])

      op = transfer_op("op-t", "group-src", "group-dst", 3_000)
      first = only_result(submit(conn, [op]))
      replay = only_result(submit(conn, [op]))

      assert replay == first
      assert get_group(conn, "group-src")["deposit_paid_cents"] == 5_000
      assert get_group(conn, "group-dst")["deposit_paid_cents"] == 3_000
      assert get_group(conn, "group-src")["revision"] == 3
      assert get_group(conn, "group-dst")["revision"] == 2
    end

    test "sees changes made by earlier operations in the same batch", %{conn: conn} do
      results =
        submit(conn, [
          open_op("group-src"),
          open_op("group-dst"),
          payment_op("op-pay", "group-src", 2_000),
          transfer_op("op-t", "group-src", "group-dst", 2_000)
        ])["results"]

      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert get_group(conn, "group-dst")["deposit_paid_cents"] == 2_000
    end
  end

  describe "corrections after transfers" do
    test "a reduction removes held cash across groups and bumps every affected group", %{
      conn: conn
    } do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 12_000)])
      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 5_000)])

      result = only_result(submit(conn, [reduce_op("op-reduce", "op-pay", 6_000)]))

      # the reduction spans both groups; its revision is the addressed
      # original payment group's
      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-src",
               "amount_cents" => 6_000,
               "outstanding_deposit_cents" => 13_500,
               "revision" => 4
             }

      source = get_group(conn, "group-src")
      destination = get_group(conn, "group-dst")

      assert Enum.map(source["rooms"], & &1["cash_paid_cents"]) == [6_000, 0]
      assert Enum.map(destination["rooms"], & &1["cash_paid_cents"]) == [0, 0]
      assert destination["deposit_paid_cents"] == 0

      # every group whose funding changed increments its revision, guarded or not
      assert source["revision"] == 4
      assert destination["revision"] == 3

      assert ledger(conn)["cash_reduced_cents"] == 6_000
      assert ledger(conn)["cash_held_cents"] == 6_000
    end

    test "a chargeback removes held cash across groups without touching uninvolved groups", %{
      conn: conn
    } do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 12_000)])
      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 5_000)])

      result = only_result(submit(conn, [charge_back_op("op-cb", "op-pay")]))

      assert result["charged_back_cents"] == 12_000
      assert result["group_id"] == "group-src"

      source = get_group(conn, "group-src")
      destination = get_group(conn, "group-dst")

      assert Enum.map(source["rooms"], & &1["cash_paid_cents"]) == [0, 0]
      assert Enum.map(destination["rooms"], & &1["cash_paid_cents"]) == [0, 0]
      assert source["revision"] == 4
      # the transferred allocation lived in the destination, so it lost
      # funding too and increments its revision as well
      assert destination["revision"] == 3

      assert ledger(conn)["cash_charged_back_cents"] == 12_000
      assert ledger(conn)["cash_held_cents"] == 0
    end

    test "a chargeback reclassifies settlements on the groups that booked them", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 6_000)])
      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 4_000)])

      # the destination settles refundably: its share of the payment becomes
      # converted-to-credit under the destination group
      submit(conn, [credit_cancel_op("op-cancel-dst", "group-dst", @refundable_on)])

      assert ledger(conn)["cash_converted_to_credit_cents"] == 4_000
      assert ledger(conn)["credit_liability_cents"] >= 4_400

      result = only_result(submit(conn, [charge_back_op("op-cb", "op-pay")]))

      assert result["charged_back_cents"] == 6_000

      # the conversion is undone on the destination, which booked it
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 6_000
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "an addressed group with no held cash still increments once", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])
      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 5_000)])

      result = only_result(submit(conn, [reduce_op("op-reduce", "op-pay", 5_000)]))

      assert result["status"] == "applied"

      # the whole held portion lived in the destination; both groups still move
      assert get_group(conn, "group-src")["revision"] == 4
      assert get_group(conn, "group-dst")["revision"] == 3
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id statement evolution" do
    test "payments never involved in a transfer keep the earlier shape", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-src",
               "recorded_cents" => 5_000,
               "held_cents" => 5_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "once transferred, the statement reports held_by_group", %{conn: conn} do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 12_000)])
      submit(conn, [transfer_op("op-t1", "group-src", "group-dst", 5_000)])

      # open a third group so several entries can exist
      submit(conn, [
        open_op("group-third"),
        transfer_op("op-t2", "group-src", "group-third", 2_000)
      ])

      assert statement(conn, "op-pay") == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-src",
               "recorded_cents" => 12_000,
               "held_cents" => 12_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "group-dst", "amount_cents" => 5_000},
                 %{"group_id" => "group-src", "amount_cents" => 5_000},
                 %{"group_id" => "group-third", "amount_cents" => 2_000}
               ]
             }
    end

    test "groups without held cash are omitted and none remains yields an empty list", %{
      conn: conn
    } do
      open_pair!(conn)
      submit(conn, [payment_op("op-pay", "group-src", 5_000)])
      submit(conn, [transfer_op("op-t", "group-src", "group-dst", 5_000)])

      # everything the payment held moved away; the source holds none
      assert statement(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-dst", "amount_cents" => 5_000}
             ]

      submit(conn, [reduce_op("op-reduce", "op-pay", 5_000)])

      assert statement(conn, "op-pay")["held_cents"] == 0
      assert statement(conn, "op-pay")["held_by_group"] == []
    end
  end

  # Helpers

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp only_result(response) do
    [result] = response["results"]
    result
  end

  defp rejection(response, code) do
    result = only_result(response)

    result["status"] == "rejected" and result["code"] == code
  end

  defp open_pair!(conn) do
    assert only_result(submit(conn, [open_op("group-src")]))["status"] == "applied"
    assert only_result(submit(conn, [open_op("group-dst")]))["status"] == "applied"
  end

  defp open_op(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-" <> group_id),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => "ams-canal",
      "arrival_on" => @arrival_on,
      "departure_on" => "2026-12-13",
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
    }
  end

  defp transfer_op(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => @booked_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp payment_op(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => @booked_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp credit_op(operation_id, group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-11-05"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, group_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp credit_cancel_op(operation_id, group_id, occurred_on) do
    cancel_op(operation_id, group_id, occurred_on)
    |> Map.put("refund_method", "hotel_credit")
  end

  defp reduce_op(operation_id, payment_operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => @booked_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_op(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => @booked_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  # Cancels a freshly paid flexible group with hotel credit so guest-22 ends
  # up with a credit lot of round(cash * 110%) expiring 366 days later.
  defp issue_credit(conn, operation_id, group_id, cash_cents, occurred_on) do
    assert only_result(submit(conn, [open_op(group_id)]))["status"] == "applied"
    submit(conn, [payment_op("op-pay-" <> group_id, group_id, cash_cents)])

    result = only_result(submit(conn, [credit_cancel_op(operation_id, group_id, occurred_on)]))
    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn), do: conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")

  defp guest_credit(conn, guest_id, opts \\ []) do
    path =
      case Keyword.fetch(opts, :on) do
        {:ok, on} -> "/api/v1/guests/#{guest_id}/credit?on=" <> on
        :error -> "/api/v1/guests/#{guest_id}/credit"
      end

    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp statement(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
