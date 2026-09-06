defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  # The default group has rooms room-a (deposit 9_000) and room-b (deposit
  # 10_500), 19_500 in total. The companion group has one room room-c
  # (lodging 30_000, deposit 6_000). Both belong to guest-22.

  describe "transfer_deposit" do
    test "moves held cash in reverse allocation order and reports both groups", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)

      run_batch(conn, [payment_operation("op-pay", 12_000)])

      # No transfer participation yet, so the statement keeps its earlier shape.
      refute Map.has_key?(statement(conn, "op-pay"), "held_by_group")

      assert [%{"status" => "applied"} = result] =
               run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 5_000)])

      assert result == %{
               "operation_id" => "op-xfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 12_500,
               "destination_outstanding_deposit_cents" => 1_000,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      # Reverse allocation order drew room-b's portion first, then part of
      # room-a's; the destination fills room-c in its original order.
      assert [
               %{"room_id" => "room-a", "cash_paid_cents" => 7_000},
               %{"room_id" => "room-b", "cash_paid_cents" => 0}
             ] = group_json(conn, "group-81")["rooms"]

      assert [
               %{"room_id" => "room-c", "cash_paid_cents" => 5_000}
             ] = group_json(conn, "group-92")["rooms"]

      assert group_json(conn, "group-81")["outstanding_deposit_cents"] == 12_500
      assert group_json(conn, "group-92")["outstanding_deposit_cents"] == 1_000

      # A transfer moves no money: the ledger total is unchanged.
      assert ledger_json(conn)["cash_held_cents"] == 12_000

      assert statement(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7_000},
               %{"group_id" => "group-92", "amount_cents" => 5_000}
             ]
    end

    test "same-batch visibility lets a transfer observe earlier operations", %{conn: conn} do
      open_default_group(conn)

      results =
        run_batch(conn, [
          open_operation(
            operation_id: "op-open-b",
            group_id: "group-92",
            property_id: "lon-thames"
          ),
          payment_operation("op-pay", 12_000),
          transfer_op("op-xfer", "group-81", "group-92", 5_000)
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied)
      assert results |> List.last() |> Map.fetch!("destination_revision") == 2
    end

    test "moves hotel credit with its lot and restores it to that lot on settlement", %{
      conn: conn
    } do
      open_default_group(conn)
      mint_credit_for_guest(conn)

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-apply",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2026-10-06",
                   "group_id" => "group-81",
                   "amount_cents" => 4_000
                 }
               ])

      open_companion_group(conn)

      assert [%{"status" => "applied"}] =
               run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 2_500)])

      # The transferred credit stays applied with its expiry paused.
      assert guest_credit_json(conn)["available_cents"] == 7_000
      assert group_json(conn, "group-92")["credit_paid_cents"] == 2_500
      assert group_json(conn, "group-81")["credit_paid_cents"] == 1_500

      # A refundable settlement returns it to its original lot and expiry.
      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-cancel-d",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-20",
                   "group_id" => "group-92"
                 }
               ])

      assert guest_credit_json(conn)["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-src",
                 "remaining_cents" => 9_500,
                 "expires_on" => "2027-11-17"
               }
             ]

      # The 1_500 still applied to the active group-81 plus the 9_500 back in
      # the lot.
      assert ledger_json(conn)["credit_liability_cents"] == 11_000
    end

    test "rejects every invalid transfer with a stable code", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)

      run_batch(conn, [
        open_operation(
          operation_id: "op-open-c",
          group_id: "group-b",
          guest_id: "guest-other",
          property_id: "lon-thames"
        )
      ])

      results =
        run_batch(conn, [
          transfer_op("op-same", "group-81", "group-81", 1_000),
          transfer_op("op-guests", "group-81", "group-b", 1_000),
          transfer_op("op-zero", "group-81", "group-92", 0),
          transfer_op("op-negative", "group-81", "group-92", -500),
          transfer_op("op-no-funding", "group-81", "group-92", 1),
          transfer_op("op-missing-source", "ghost", "group-92", 1),
          transfer_op("op-missing-destination", "group-81", "ghost", 1)
        ])

      assert Enum.map(results, &{&1["code"], &1["group_id"]}) == [
               {"invalid_transfer", nil},
               {"invalid_transfer", nil},
               {"invalid_amount", "group-81"},
               {"invalid_amount", "group-81"},
               {"transfer_exceeds_held_funding", "group-81"},
               {"group_not_found", "ghost"},
               {"group_not_found", "ghost"}
             ]
    end

    test "destination outstanding bounds the transfer", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)

      run_batch(conn, [payment_operation("op-pay", 12_000)])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_outstanding"} = rejection] =
               run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 6_001)])

      assert rejection["group_id"] == "group-92"
      assert group_json(conn, "group-81")["revision"] == 2
    end

    test "existence resolves before revisions, then source before destination", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)

      run_batch(conn, [
        payment_operation("op-pay-a", 1_000),
        payment_operation("op-pay-b", 1_000, "group-92")
      ])

      results =
        run_batch(conn, [
          transfer_op("op-missing-first", "ghost", "group-92", 1)
          |> Map.put("expected_revision", 999),
          transfer_op("op-source-stale", "group-81", "group-92", 1)
          |> Map.put("expected_revision", 1),
          transfer_op("op-destination-stale", "group-81", "group-92", 1)
          |> Map.put("expected_revision", 2)
          |> Map.put("destination_expected_revision", 1)
        ])

      assert [
               %{"code" => "group_not_found"},
               %{"code" => "stale_revision"} = source_stale,
               %{"code" => "stale_revision"} = destination_stale
             ] = results

      assert source_stale["group_id"] == "group-81"
      assert source_stale["expected_revision"] == 1
      assert source_stale["actual_revision"] == 2

      assert destination_stale["group_id"] == "group-92"
      assert destination_stale["expected_revision"] == 1
      assert destination_stale["actual_revision"] == 2

      # Rejections never increment either group.
      assert group_json(conn, "group-81")["revision"] == 2
      assert group_json(conn, "group-92")["revision"] == 2
    end

    test "inactive groups are rejected with their own identifier", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-92"
        },
        payment_operation("op-pay", 1_000)
      ])

      results =
        run_batch(conn, [
          transfer_op("op-from-inactive", "group-92", "group-81", 1),
          transfer_op("op-to-inactive", "group-81", "group-92", 1)
        ])

      assert Enum.map(results, &{&1["code"], &1["group_id"]}) == [
               {"group_not_active", "group-92"},
               {"group_not_active", "group-92"}
             ]
    end

    test "transferred cash settles under the destination group's cancellation policy", %{
      conn: conn
    } do
      open_default_group(conn)
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])
      run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 5_000)])

      # Refundable cancellation of the destination with hotel credit converts
      # the transferred cash there, with the standard bonus.
      assert [%{"status" => "applied"} = result] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-cancel-d",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-20",
                   "group_id" => "group-92",
                   "refund_method" => "hotel_credit"
                 }
               ])

      assert result["credit_issued_cents"] == 5_500
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert guest_credit_json(conn)["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-d",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-11-21"
               }
             ]

      # The original payment followed its allocation to the other group.
      statement = statement(conn, "op-pay")

      assert statement["held_cents"] == 7_000
      assert statement["converted_to_credit_cents"] == 5_000
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 7_000}]

      ledger = ledger_json(conn)

      assert ledger["cash_converted_to_credit_cents"] == 5_000
      assert ledger["cash_held_cents"] == 7_000
    end

    test "retries replay the stored result without moving funding again", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      first = transfer_op("op-xfer", "group-81", "group-92", 5_000)
      assert [%{"status" => "applied"} = stored] = run_batch(conn, [first])

      assert [%{"status" => "applied"} = replayed] = run_batch(conn, [first])
      assert replayed == stored
      assert group_json(conn, "group-92")["cash_paid_cents"] == 5_000
      assert group_json(conn, "group-92")["revision"] == 2

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 6_000)])
    end
  end

  describe "reductions and chargebacks across groups" do
    test "a reduction removes held allocations in reverse order across groups", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])
      run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 5_000)])

      # The transferred chunks are the most recent allocations, so the whole
      # reduction comes out of the destination even though the request guards
      # only the original payment group.
      assert [%{"status" => "applied"} = result] =
               run_batch(conn, [reduce_op("op-reduce", "op-pay", 4_000)])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 4_000,
               "outstanding_deposit_cents" => 12_500,
               "revision" => 4
             }

      # The unguarded destination still increments its revision exactly once.
      assert group_json(conn, "group-92")["revision"] == 3
      assert group_json(conn, "group-92")["cash_paid_cents"] == 1_000
      assert group_json(conn, "group-81")["cash_paid_cents"] == 7_000

      assert statement(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7_000},
               %{"group_id" => "group-92", "amount_cents" => 1_000}
             ]
    end

    test "a chargeback reverses held funding wherever it currently sits", %{conn: conn} do
      open_default_group(conn)
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])
      run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 5_000)])

      assert [%{"status" => "applied"} = result] =
               run_batch(conn, [charge_back_op("op-chb", "op-pay")])

      assert result["charged_back_cents"] == 12_000
      assert result["group_id"] == "group-81"
      assert result["revision"] == 4

      assert group_json(conn, "group-92")["revision"] == 3
      assert group_json(conn, "group-92")["cash_paid_cents"] == 0
      assert group_json(conn, "group-92")["outstanding_deposit_cents"] == 6_000
      assert group_json(conn, "group-81")["cash_paid_cents"] == 0
      assert ledger_json(conn)["cash_charged_back_cents"] == 12_000

      # None remains held, so the evolved statement carries an empty list.
      assert statement(conn, "op-pay")["held_by_group"] == []
    end

    test "the original group's revision is returned even without held allocations", %{
      conn: conn
    } do
      open_default_group(conn)
      run_batch(conn, [payment_operation("op-pay", 6_000)])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-12-01",
                   "group_id" => "group-81"
                 }
               ])

      assert [%{"status" => "applied"} = result] =
               run_batch(conn, [charge_back_op("op-chb", "op-pay")])

      assert result["revision"] == 4
      assert result["charged_back_cents"] == 6_000
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp open_default_group(conn), do: open_group(conn, %{})

  defp open_companion_group(conn) do
    open_group(conn, %{
      "operation_id" => "op-open-b",
      "group_id" => "group-92",
      "property_id" => "lon-thames",
      "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 10_000}]
    })
  end

  defp open_group(conn, overrides) do
    assert [%{"status" => "applied"}] =
             run_batch(conn, [struct_map(open_operation(), overrides)])

    :ok
  end

  defp struct_map(base, overrides), do: Map.merge(base, overrides)

  defp mint_credit_for_guest(conn) do
    assert [%{"status" => "applied"}, _, _] =
             run_batch(conn, [
               open_operation(
                 operation_id: "op-open-src",
                 group_id: "group-src",
                 arrival_on: "2027-01-15",
                 departure_on: "2027-01-16",
                 rooms: [%{"room_id" => "room-x", "nightly_rate_cents" => 50_000}]
               ),
               payment_operation("op-pay-src", 10_000)
               |> Map.put("group_id", "group-src"),
               %{
                 "operation_id" => "op-cancel-src",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-16",
                 "group_id" => "group-src",
                 "refund_method" => "hotel_credit"
               }
             ])

    :ok
  end

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn, group_id) do
    %{"data" => group} = conn |> get_group(group_id) |> json_response(200)
    group
  end

  defp ledger_json(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
  end

  defp guest_credit_json(conn) do
    %{"data" => data} = conn |> get_guest_credit("guest-22") |> json_response(200)
    data
  end

  defp statement(conn, payment_operation_id) do
    %{"data" => data} = conn |> get_payment(payment_operation_id) |> json_response(200)
    data
  end

  defp payment_operation(operation_id, amount_cents, group_id \\ "group-81") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-06",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_op(operation_id, target_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => target_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_op(operation_id, target_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-08",
      "payment_operation_id" => target_id
    }
  end
end
