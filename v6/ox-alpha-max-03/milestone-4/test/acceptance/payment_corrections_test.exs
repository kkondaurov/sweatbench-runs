defmodule GroupStay.Acceptance.PaymentCorrectionsTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"
  @refundable_until_flex14 "2026-11-26"

  defp open_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @open_occurred_on),
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
    }
  end

  defp cash_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_operation(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-10-05",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(operation_id, group_id, occurred_on \\ @refundable_until_flex14) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  defp cancel_rooms_operation(operation_id, group_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => @refundable_until_flex14,
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp reduce_operation(operation_id, payment_operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-06",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => payment_operation_id
    }
  end

  defp post_batch(_conn, operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group!(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp get_ledger! do
    build_conn() |> get("/api/v1/ledger") |> json_response(200)
  end

  defp get_statement!(payment_operation_id) do
    build_conn() |> get("/api/v1/payments/#{payment_operation_id}") |> json_response(200)
  end

  defp get_operation!(operation_id) do
    build_conn() |> get("/api/v1/operations/#{operation_id}") |> json_response(200)
  end

  # Opens group-live and pays 12_000 with pay-1: room-a holds 9_000 and
  # room-b holds 3_000.
  setup do
    results =
      post_batch(
        build_conn(),
        [
          open_operation("group-live"),
          cash_operation("pay-1", "group-live", 12_000)
        ]
      )

    assert [%{"status" => "applied"}, %{"status" => "applied"}] = results
    :ok
  end

  describe "reduce_cash_payment" do
    test "removes held allocations in reverse fill order and reopens the deposit", %{conn: conn} do
      results = post_batch(conn, [reduce_operation("op-reduce-1", "pay-1", 2_000)])

      assert [
               %{
                 "operation_id" => "op-reduce-1",
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-live",
                 "amount_cents" => 2_000,
                 "outstanding_deposit_cents" => 9_500,
                 "revision" => 3
               }
             ] = results

      # The removal comes off room-b's tail allocation first.
      assert %{
               "data" => %{
                 "cash_paid_cents" => 10_000,
                 "deposit_due_cents" => 19_500,
                 "outstanding_deposit_cents" => 9_500,
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 9_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 1_000}
                 ]
               }
             } = get_group!("group-live")

      assert %{
               "data" => %{
                 "cash_held_cents" => 10_000,
                 "cash_reduced_cents" => 2_000,
                 "cash_refunded_cents" => 0
               }
             } = get_ledger!()

      assert %{
               "data" => %{
                 "payment_operation_id" => "pay-1",
                 "original_group_id" => "group-live",
                 "recorded_cents" => 12_000,
                 "held_cents" => 10_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 2_000,
                 "charged_back_cents" => 0
               }
             } = get_statement!("pay-1")
    end

    test "successive reductions compose against remaining held cash", %{conn: conn} do
      post_batch(conn, [
        reduce_operation("op-reduce-1", "pay-1", 2_000),
        reduce_operation("op-reduce-2", "pay-1", 5_000),
        reduce_operation("op-reduce-all", "pay-1", 5_000)
      ])

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "reduced_cents" => 12_000,
                 "recorded_cents" => 12_000
               }
             } = get_statement!("pay-1")

      assert %{"data" => %{"cash_reduced_cents" => 12_000, "cash_held_cents" => 0}} =
               get_ledger!()
    end

    test "rejects a reduction larger than currently held cash", %{conn: conn} do
      post_batch(conn, [reduce_operation("op-reduce-1", "pay-1", 2_000)])

      results = post_batch(conn, [reduce_operation("op-reduce-big", "pay-1", 11_000)])

      assert [%{"status" => "rejected", "code" => "reduction_exceeds_held_cash"}] = results

      # Nothing changed.
      assert %{"data" => %{"held_cents" => 10_000, "reduced_cents" => 2_000}} =
               get_statement!("pay-1")
    end

    test "rejects non-positive amounts as invalid_amount", %{conn: conn} do
      results =
        post_batch(conn, [
          reduce_operation("op-zero", "pay-1", 0),
          reduce_operation("op-negative", "pay-1", -100)
        ])

      assert [%{"code" => "invalid_amount"}, %{"code" => "invalid_amount"}] = results
    end

    test "returns operation_not_found without a durable record", %{conn: conn} do
      results = post_batch(conn, [reduce_operation("op-reduce-x", "pay-nowhere", 100)])

      assert [%{"status" => "rejected", "code" => "operation_not_found"}] = results
    end

    test "rejects targets that can never accept a positive reduction", %{conn: conn} do
      post_batch(conn, [
        cash_operation("pay-too-much", "group-live", 999_999),
        cancel_operation("op-cancel", "group-live")
      ])

      results =
        post_batch(conn, [
          reduce_operation("op-red-cancel", "op-cancel", 100),
          reduce_operation("op-red-rejected", "pay-too-much", 100),
          reduce_operation("op-red-settled", "pay-1", 100)
        ])

      assert [
               %{"code" => "payment_not_reducible"},
               %{"code" => "payment_not_reducible"},
               %{"code" => "payment_not_reducible"}
             ] = results
    end

    test "rejects stale revisions against the original payment's group", %{conn: conn} do
      stale =
        reduce_operation("op-stale", "pay-1", 1_000)
        |> Map.put("expected_revision", 1)

      results = post_batch(conn, [stale])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-live",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = results
    end

    test "is durably idempotent and never rewrites the original payment result", %{conn: conn} do
      operation = reduce_operation("op-once", "pay-1", 2_000)

      first = post_batch(conn, [operation])
      retry = post_batch(conn, [operation])

      expected = %{
        "operation_id" => "op-once",
        "status" => "applied",
        "payment_operation_id" => "pay-1",
        "group_id" => "group-live",
        "amount_cents" => 2_000,
        "outstanding_deposit_cents" => 9_500,
        "revision" => 3
      }

      assert [^expected] = first
      assert [^expected] = retry

      conflicting = reduce_operation("op-once", "pay-1", 3_000)

      assert [%{"code" => "operation_id_conflict"}] = post_batch(conn, [conflicting])

      # The original payment's stored result is untouched by the correction.
      assert %{
               "data" => %{
                 "operation_id" => "pay-1",
                 "status" => "applied",
                 "amount_cents" => 12_000,
                 "outstanding_deposit_cents" => 7_500,
                 "revision" => 2
               }
             } = get_operation!("pay-1")
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash and reopens the active rooms' outstanding deposit", %{conn: conn} do
      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [
               %{
                 "operation_id" => "op-cb",
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-live",
                 "charged_back_cents" => 12_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 3
               }
             ] = results

      assert %{"data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 12_000}} =
               get_ledger!()

      assert %{
               "data" => %{
                 "recorded_cents" => 12_000,
                 "held_cents" => 0,
                 "charged_back_cents" => 12_000
               }
             } = get_statement!("pay-1")

      # The chargeback increments the group's revision exactly once...
      assert %{"data" => %{"revision" => 3}} = get_group!("group-live")
    end

    test "reclassifies refunded and retained history without reversing it", %{conn: conn} do
      # Refundable cancellation of one room refunds 3_000 of pay-1's cash.
      post_batch(conn, [cancel_rooms_operation("op-cancel-b", "group-live", ["room-b"])])

      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [%{"status" => "applied", "charged_back_cents" => 12_000}] = results

      assert %{
               "data" => %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 12_000
               }
             } = get_statement!("pay-1")

      # The historical refund entry stays on the ledger; only the payment's
      # classification changed.
      assert %{
               "data" => %{
                 "cash_refunded_cents" => 3_000,
                 "cash_charged_back_cents" => 12_000,
                 "cash_held_cents" => 0
               }
             } = get_ledger!()
    end

    test "works on a cancelled group that retained the cash", %{conn: conn} do
      post_batch(conn, [cancel_operation("op-late-cancel", "group-live", "2026-12-01")])

      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [%{"status" => "applied", "charged_back_cents" => 12_000}] = results

      assert %{"data" => %{"cash_retained_cents" => 12_000, "cash_charged_back_cents" => 12_000}} =
               get_ledger!()

      assert %{
               "data" => %{
                 "retained_cents" => 0,
                 "charged_back_cents" => 12_000,
                 "recorded_cents" => 12_000
               }
             } = get_statement!("pay-1")
    end

    test "revokes the credit entitlement created by converted cash", %{conn: conn} do
      # pay-1's cash becomes an 13_200 lot on a refundable hotel-credit cancel.
      post_batch(conn, [
        cancel_operation("op-convert", "group-live")
        |> Map.put("refund_method", "hotel_credit")
      ])

      assert %{"data" => %{"available_cents" => 13_200}} = guest_credit!()

      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [%{"status" => "applied", "charged_back_cents" => 12_000}] = results

      # The principal moved to charged-back cash and the entitlement is gone.
      assert %{"data" => %{"available_cents" => 0, "lots" => []}} = guest_credit!()

      assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger!()

      assert %{
               "data" => %{
                 "converted_to_credit_cents" => 0,
                 "charged_back_cents" => 12_000
               }
             } = get_statement!("pay-1")
    end

    test "assigns entitlement across payments in funding order when several converted", %{
      conn: conn
    } do
      # pay-1 holds 12_000 (9_000 + 3_000); pay-2 adds another 4_000.
      post_batch(conn, [cash_operation("pay-2", "group-live", 4_000)])

      post_batch(conn, [
        cancel_operation("op-convert", "group-live")
        |> Map.put("refund_method", "hotel_credit")
      ])

      # One lot worth V(16_000) = 17_600. Entitlements telescope:
      # pay-1 -> V(12_000) = 13_200; pay-2 -> 17_600 - 13_200 = 4_400.
      assert %{"data" => %{"available_cents" => 17_600, "lots" => [lot]}} = guest_credit!()
      assert %{"remaining_cents" => 17_600} = lot

      post_batch(conn, [charge_back_operation("op-cb-2", "pay-2")])

      assert %{"data" => %{"available_cents" => 13_200}} = guest_credit!()

      post_batch(conn, [charge_back_operation("op-cb-1", "pay-1")])

      assert %{"data" => %{"available_cents" => 0}} = guest_credit!()
    end

    test "a clawback that cannot be recovered becomes the lot's shortfall", %{conn: conn} do
      # Convert pay-1 into a 13_200 lot, then apply 5_000 of it to a second,
      # still-active group so only 8_200 remains revocable.
      post_batch(conn, [
        cancel_operation("op-convert", "group-live")
        |> Map.put("refund_method", "hotel_credit")
      ])

      post_batch(conn, [
        open_operation("group-two"),
        apply_credit_operation("op-apply", "group-two", 5_000)
      ])

      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [%{"status" => "applied", "charged_back_cents" => 12_000}] = results

      assert %{
               "data" => %{
                 "available_cents" => 0,
                 "lots" => []
               }
             } = guest_credit!()

      assert %{"data" => %{"credit_shortfall_cents" => 5_000, "credit_liability_cents" => 5_000}} =
               get_ledger!()

      # A non-refundable settlement consumes the applied credit, which resolves
      # the shortfall automatically because nothing is applied anymore.
      post_batch(conn, [cancel_operation("op-late-two", "group-two", "2026-12-01")])

      assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}} =
               get_ledger!()
    end

    test "restored credit extinguishes unrecovered clawback before expiring", %{conn: conn} do
      post_batch(conn, [
        cancel_operation("op-convert", "group-live")
        |> Map.put("refund_method", "hotel_credit")
      ])

      post_batch(conn, [
        open_operation("group-two"),
        apply_credit_operation("op-apply", "group-two", 5_000)
      ])

      post_batch(conn, [charge_back_operation("op-cb", "pay-1")])
      assert %{"data" => %{"credit_shortfall_cents" => 5_000}} = get_ledger!()

      # A refundable cancellation returns the applied credit to the shortfalled
      # lot; it is absorbed instead of becoming available again.
      post_batch(conn, [cancel_operation("op-cancel-two", "group-two")])

      assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}} =
               get_ledger!()

      assert %{"data" => %{"available_cents" => 0}} = guest_credit!()
    end

    test "does not change revisions or state of groups funded by the affected credit", %{
      conn: conn
    } do
      post_batch(conn, [
        cancel_operation("op-convert", "group-live") |> Map.put("refund_method", "hotel_credit"),
        open_operation("group-two"),
        apply_credit_operation("op-apply", "group-two", 1_000)
      ])

      post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      # group-two keeps its own revision even though its credit came from the
      # same lot the chargeback clawed back from.
      assert %{"data" => %{"revision" => 2, "status" => "active"}} = get_group!("group-two")
    end

    test "rejects records that are not applied cash payments or are already charged back", %{
      conn: conn
    } do
      post_batch(conn, [
        cancel_operation("op-cancel", "group-live"),
        cash_operation("pay-rejected", "group-live", 999_999),
        charge_back_operation("op-cb-first", "pay-1")
      ])

      results =
        post_batch(conn, [
          charge_back_operation("op-cb-again", "pay-1"),
          charge_back_operation("op-cb-cancel-op", "op-cancel"),
          charge_back_operation("op-cb-rejected", "pay-rejected"),
          charge_back_operation("op-cb-missing", "pay-missing")
        ])

      assert [
               %{"code" => "payment_not_chargeable"},
               %{"code" => "payment_not_chargeable"},
               %{"code" => "payment_not_chargeable"},
               %{"code" => "operation_not_found"}
             ] = results
    end

    test "rejects a fully reduced payment as not chargeable", %{conn: conn} do
      post_batch(conn, [reduce_operation("op-reduce-all", "pay-1", 12_000)])

      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [%{"code" => "payment_not_chargeable"}] = results
    end

    test "is durably idempotent", %{conn: conn} do
      operation = charge_back_operation("op-cb", "pay-1")

      assert [%{"status" => "applied"}] = post_batch(conn, [operation])
      retry_results = post_batch(conn, [operation])

      assert [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 12_000,
                 "revision" => 3
               }
             ] = retry_results

      # The replay neither charged back twice nor bumped the revision again.
      assert %{"data" => %{"revision" => 3}} = get_group!("group-live")
      assert %{"data" => %{"cash_charged_back_cents" => 12_000}} = get_ledger!()
    end
  end

  describe "GET /api/v1/payments/:payment_operation_id" do
    test "reports every disposition with zeros included and exact sums", %{conn: conn} do
      post_batch(conn, [
        reduce_operation("op-reduce", "pay-1", 500)
      ])

      # Refundable hotel-credit cancellation converts part of the cash.
      post_batch(conn, [
        cancel_rooms_operation("op-cancel-b", "group-live", ["room-b"])
      ])

      statement = get_statement!("pay-1")["data"]

      assert %{
               "payment_operation_id" => "pay-1",
               "original_group_id" => "group-live",
               "recorded_cents" => recorded,
               "held_cents" => held,
               "refunded_cents" => refunded,
               "retained_cents" => retained,
               "converted_to_credit_cents" => converted,
               "reduced_cents" => reduced,
               "charged_back_cents" => charged_back
             } = statement

      assert map_size(statement) == 9
      assert held + refunded + retained + converted + reduced + charged_back == recorded

      # The 500 reduction came off room-b's tail; cancelling room-b later
      # refunded only what it still held.
      assert {held, refunded, retained, converted, reduced, charged_back} ==
               {9_000, 2_500, 0, 0, 500, 0}
    end

    test "agrees with group, room, and ledger views", %{conn: conn} do
      post_batch(conn, [cancel_rooms_operation("op-cancel-a", "group-live", ["room-a"])])

      statement = get_statement!("pay-1")
      group = get_group!("group-live")

      held_in_rooms =
        group["data"]["rooms"]
        |> Enum.filter(&(&1["status"] == "active"))
        |> Enum.map(& &1["cash_paid_cents"])
        |> Enum.sum()

      assert statement["data"]["held_cents"] == held_in_rooms
      assert group["data"]["cash_paid_cents"] == held_in_rooms
      assert get_ledger!()["data"]["cash_held_cents"] == held_in_rooms
    end

    test "returns 404 for unknown identifiers", %{conn: _conn} do
      conn = build_conn() |> get("/api/v1/payments/pay-missing")

      assert %{"error" => %{"code" => "operation_not_found"}} = json_response(conn, 404)
    end

    test "returns 422 payment_not_reconcilable for non-payment records", %{conn: conn} do
      post_batch(conn, [
        cancel_operation("op-cancel", "group-live"),
        cash_operation("pay-rejected", "group-live", 999_999)
      ])

      for id <- ["op-cancel", "pay-rejected", "op-open-group-live"] do
        conn = build_conn() |> get("/api/v1/payments/#{id}")
        assert %{"error" => %{"code" => "payment_not_reconcilable"}} = json_response(conn, 422)
      end
    end

    test "reading a statement never changes state", %{conn: _conn} do
      before_group = get_group!("group-live")
      before_ledger = get_ledger!()

      get_statement!("pay-1")
      get_statement!("pay-1")

      assert get_group!("group-live") == before_group
      assert get_ledger!() == before_ledger
    end
  end

  describe "clawback absorption in restored lots" do
    # One lot worth V(16_000) = 17_600 funded by two payments: p1 -> 13_200,
    # p2 -> 4_400. A group applies 9_000, leaving 8_600 revocable when p1 is
    # charged back, so p1's clawback recovers 8_600 and leaves 4_600
    # unrecovered. The fungible restoration of all 9_000 then extinguishes the
    # unrecovered clawback first and only the 4_400 excess can become
    # available.
    defp multi_payment_lot(conn) do
      results =
        post_batch(conn, [
          cash_operation("pay-2", "group-live", 4_000),
          cancel_operation("op-convert", "group-live")
          |> Map.put("refund_method", "hotel_credit"),
          open_operation("group-two"),
          apply_credit_operation("op-apply", "group-two", 9_000)
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"}
             ] =
               results

      post_batch(conn, [charge_back_operation("op-cb-p1", "pay-1")])

      assert %{"data" => %{"available_cents" => 0}} = guest_credit!()

      assert %{"data" => %{"credit_shortfall_cents" => 4_600, "credit_liability_cents" => 9_000}} =
               get_ledger!()
    end

    test "excess after absorption becomes available while the lot is unexpired", %{conn: conn} do
      multi_payment_lot(conn)

      # The lot expires 2027-11-27; cancelling refundably before that date
      # returns the credit to the shortfalled lot.
      results =
        post_batch(conn, [cancel_operation("op-cancel-two", "group-two")])

      assert [%{"status" => "applied", "refunded_cents" => 0}] = results

      assert %{"data" => %{"available_cents" => 4_400}} = guest_credit!()

      assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 4_400}} =
               get_ledger!()
    end

    test "excess after absorption expires immediately once the lot has expired", %{conn: conn} do
      multi_payment_lot(conn)

      # Move the stay beyond the lot's expiry and cancel refundably there:
      # absorption still happens first; only the expiry decides on the excess.
      post_batch(conn, [
        %{
          "operation_id" => "op-move",
          "type" => "reschedule_group",
          "occurred_on" => "2027-12-01",
          "group_id" => "group-two",
          "new_arrival_on" => "2028-06-10"
        },
        cancel_operation("op-cancel-two", "group-two", "2027-12-01")
      ])

      assert %{"data" => %{"available_cents" => 0}} = guest_credit!()

      assert %{"data" => %{"credit_shortfall_cents" => 0, "credit_liability_cents" => 0}} =
               get_ledger!()
    end
  end

  defp guest_credit! do
    build_conn() |> get("/api/v1/guests/guest-22/credit") |> json_response(200)
  end
end
