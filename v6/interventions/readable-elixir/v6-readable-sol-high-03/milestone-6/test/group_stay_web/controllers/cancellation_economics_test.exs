defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  describe "versioned cancellation policies" do
    test "fixes policy at booking, recomputes deadlines when moved, and honors the boundary", %{
      conn: conn
    } do
      old_flexible = open_group("old", "guest", "2026-12-31", "2027-06-01")
      new_flexible = open_group("new", "guest", "2027-01-01", "2027-06-01")

      advance =
        open_group("advance", "guest", "2027-01-01", "2027-06-01", %{
          "rate_plan" => "advance_purchase"
        })

      assert %{"results" => results} = submit(conn, [old_flexible, new_flexible, advance])
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-05-18"
             } = fetch_group(conn, "old")

      assert %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-05-02"
             } = fetch_group(conn, "new")

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = fetch_group(conn, "advance")

      move = %{
        "operation_id" => "move-old",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-02",
        "group_id" => "old",
        "new_arrival_on" => "2027-07-01"
      }

      pay_new = cash_payment("pay-new", "new", 1_000, "2027-01-02")
      cancel_new = cancellation("cancel-new", "new", "2027-05-02")

      assert %{"results" => [moved, _paid, cancelled]} =
               submit(conn, [move, pay_new, cancel_new])

      assert %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-06-17"
             } = moved

      assert cancelled["refunded_cents"] == 1_000
    end
  end

  describe "issuing and reporting hotel credit" do
    test "converts refundable cash with rounded bonus and expires after day 365", %{conn: conn} do
      operations = [
        open_group("source", "guest-22", "2026-09-01", "2026-12-10"),
        cash_payment("pay-source", "source", 1_005, "2026-09-02"),
        cancellation("cancel-source", "source", "2026-10-01", "hotel_credit")
      ]

      assert %{"results" => [_opened, _paid, cancelled]} = submit(conn, operations)

      assert cancelled == %{
               "operation_id" => "cancel-source",
               "status" => "applied",
               "group_id" => "source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_106,
               "revision" => 3
             }

      assert credit(conn, "guest-22", "2027-10-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 1_106,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 1_106,
                   "expires_on" => "2027-10-02"
                 }
               ]
             }

      assert credit(conn, "guest-22", "2027-10-02")["available_cents"] == 0

      assert ledger(conn, "2026-10-01") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1_005,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 1_106,
               "credit_shortfall_cents" => 0
             }

      assert ledger(conn, "2027-10-02")["credit_liability_cents"] == 0
    end

    test "rejects hotel credit for non-refundable cancellation without changing state", %{
      conn: conn
    } do
      operations = [
        open_group("advance", "guest", "2027-01-01", "2027-06-01", %{
          "rate_plan" => "advance_purchase"
        }),
        cash_payment("pay", "advance", 2_000, "2027-01-02"),
        cancellation("cancel", "advance", "2027-01-03", "hotel_credit")
      ]

      assert %{"results" => [_opened, _paid, rejected]} = submit(conn, operations)
      assert rejected == rejection("cancel", "refund_method_not_available")

      assert %{"status" => "active", "revision" => 2, "cash_paid_cents" => 2_000} =
               fetch_group(conn, "advance")

      assert ledger(conn, "2027-01-03")["cash_held_cents"] == 2_000
    end
  end

  describe "applying and settling hotel credit" do
    test "uses earliest-expiring lots, preserves liability, and restores original lots", %{
      conn: conn
    } do
      issue_two_lots(conn)

      operations = [
        open_group("target", "guest", "2026-10-03", "2027-12-10"),
        apply_credit("apply-1", "target", 700, "2026-10-04", 1),
        apply_credit("apply-2", "target", 800, "2026-10-04", 2)
      ]

      assert %{"results" => [_opened, first_application, applied]} = submit(conn, operations)
      assert first_application["revision"] == 2

      assert applied == %{
               "operation_id" => "apply-2",
               "status" => "applied",
               "group_id" => "target",
               "amount_cents" => 800,
               "outstanding_deposit_cents" => 18_000,
               "revision" => 3
             }

      assert %{
               "deposit_paid_cents" => 1_500,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 1_500
             } = fetch_group(conn, "target")

      assert credit(conn, "guest", "2026-10-04") == %{
               "guest_id" => "guest",
               "available_cents" => 1_800,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source-2",
                   "remaining_cents" => 1_800,
                   "expires_on" => "2027-10-03"
                 }
               ]
             }

      assert ledger(conn, "2027-10-02")["credit_liability_cents"] == 3_300

      assert %{"results" => [cancelled]} =
               submit(conn, [cancellation("cancel-target", "target", "2026-11-01")])

      assert cancelled["refunded_cents"] == 0
      assert cancelled["credit_issued_cents"] == 0

      restored = credit(conn, "guest", "2026-11-01")
      assert restored["available_cents"] == 3_300
      assert Enum.map(restored["lots"], & &1["remaining_cents"]) == [1_100, 2_200]
    end

    test "drops an allocation restored after its original expiry", %{conn: conn} do
      issue_one_lot(conn)

      submit(conn, [
        open_group("target", "guest", "2026-10-03", "2027-12-10"),
        apply_credit("apply", "target", 1_100, "2026-10-04")
      ])

      assert ledger(conn, "2027-10-02")["credit_liability_cents"] == 1_100

      assert %{"results" => [cancelled]} =
               submit(conn, [cancellation("cancel-target", "target", "2027-10-02")])

      assert cancelled["status"] == "applied"
      assert credit(conn, "guest", "2027-10-02")["available_cents"] == 0
      assert ledger(conn, "2027-10-02")["credit_liability_cents"] == 0
    end

    test "only bonuses newly converted cash in a mixed refundable settlement", %{conn: conn} do
      issue_one_lot(conn)

      operations = [
        open_group("target", "guest", "2026-10-03", "2027-12-10"),
        apply_credit("apply", "target", 600, "2026-10-04"),
        cash_payment("pay-target", "target", 500, "2026-10-04"),
        cancellation("cancel-target", "target", "2026-11-01", "hotel_credit")
      ]

      assert %{"results" => [_opened, _credit, _cash, cancelled]} = submit(conn, operations)

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 550,
               "revision" => 4
             } = cancelled

      restored = credit(conn, "guest", "2026-11-01")
      assert restored["available_cents"] == 1_650
      assert Enum.map(restored["lots"], & &1["remaining_cents"]) == [1_100, 550]

      assert %{
               "cash_converted_to_credit_cents" => 1_500,
               "credit_liability_cents" => 1_650
             } = ledger(conn, "2026-11-01")
    end

    test "rejects insufficient credit after revision checking and consumes credit non-refundably",
         %{conn: conn} do
      issue_one_lot(conn)

      submit(conn, [
        open_group("advance", "guest", "2026-10-03", "2027-12-10", %{
          "rate_plan" => "advance_purchase"
        })
      ])

      stale = apply_credit("stale", "advance", -1, "2026-10-04", 9)
      insufficient = apply_credit("too-much", "advance", 1_101, "2026-10-04", 1)
      apply = apply_credit("apply", "advance", 600, "2026-10-04", 1)
      cash = cash_payment("pay", "advance", 500, "2026-10-04")
      cancel = cancellation("cancel-advance", "advance", "2026-10-05")

      assert %{"results" => [stale_result, insufficient_result, applied, _paid, cancelled]} =
               submit(conn, [stale, insufficient, apply, cash, cancel])

      assert stale_result["code"] == "stale_revision"
      assert insufficient_result == rejection("too-much", "insufficient_credit")
      assert applied["revision"] == 2
      assert cancelled["retained_cents"] == 500
      assert cancelled["credit_issued_cents"] == 0
      assert ledger(conn, "2026-10-05")["credit_liability_cents"] == 500
    end
  end

  test "date-filtered reads reject malformed dates", %{conn: conn} do
    assert conn |> get("/api/v1/ledger?on=not-a-date") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }

    assert conn |> get("/api/v1/guests/guest/credit?on=2027-99-01") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }
  end

  defp issue_one_lot(conn) do
    submit(conn, [
      open_group("source-1", "guest", "2026-09-01", "2026-12-10"),
      cash_payment("pay-source-1", "source-1", 1_000, "2026-09-02"),
      cancellation("cancel-source-1", "source-1", "2026-10-01", "hotel_credit")
    ])
  end

  defp issue_two_lots(conn) do
    issue_one_lot(conn)

    submit(conn, [
      open_group("source-2", "guest", "2026-09-01", "2026-12-10"),
      cash_payment("pay-source-2", "source-2", 2_000, "2026-09-02"),
      cancellation("cancel-source-2", "source-2", "2026-10-02", "hotel_credit")
    ])
  end

  defp open_group(group_id, guest_id, booked_on, arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => booked_on,
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => arrival_on,
        "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 3) |> Date.to_iso8601(),
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 32_500}]
      },
      overrides
    )
  end

  defp cash_payment(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit(operation_id, group_id, amount_cents, occurred_on, revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put_revision(revision)
  end

  defp cancellation(operation_id, group_id, occurred_on, refund_method \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
    |> maybe_put_refund_method(refund_method)
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp fetch_group(conn, group_id) do
    %{"data" => group} = conn |> get("/api/v1/groups/#{group_id}") |> json_response(200)
    group
  end

  defp credit(conn, guest_id, on) do
    %{"data" => credit} =
      conn |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}") |> json_response(200)

    credit
  end

  defp ledger(conn, on) do
    %{"data" => ledger} = conn |> get("/api/v1/ledger?on=#{on}") |> json_response(200)
    ledger
  end

  defp rejection(operation_id, code),
    do: %{"operation_id" => operation_id, "status" => "rejected", "code" => code}

  defp maybe_put_revision(operation, nil), do: operation

  defp maybe_put_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)

  defp maybe_put_refund_method(operation, nil), do: operation

  defp maybe_put_refund_method(operation, refund_method),
    do: Map.put(operation, "refund_method", refund_method)
end
