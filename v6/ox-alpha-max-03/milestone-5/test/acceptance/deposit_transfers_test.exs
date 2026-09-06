defmodule GroupStay.Acceptance.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"
  @transfer_occurred_on "2026-10-06"
  @refundable_until_flex14 "2026-11-26"

  # Rooms a and b: lodgings 45_000 and 52_500; deposits 9_000 and 10_500.
  defp open_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @open_occurred_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
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

  defp transfer_operation(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => @transfer_occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
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

  defp reduce_operation(operation_id, payment_operation_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-07",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-08",
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

  defp guest_credit! do
    build_conn() |> get("/api/v1/guests/guest-22/credit") |> json_response(200)
  end

  # Gives guest-22 an 8_800 credit lot (expiring 2027-11-27) through a
  # refundable hotel-credit cancellation of a helper group.
  defp give_guest_credit(_conn) do
    results =
      post_batch(build_conn(), [
        open_operation("group-credit-source"),
        cash_operation("op-pay-source", "group-credit-source", 8_000),
        cancel_operation("op-cancel-source", "group-credit-source")
        |> Map.put("refund_method", "hotel_credit")
      ])

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             results
  end

  # Two active groups of one guest; pay-1 holds 12_000 on group-live
  # (room-a 9_000, room-b 3_000). Revisions are 2 and 1.
  setup do
    results =
      post_batch(
        build_conn(),
        [
          open_operation("group-live"),
          open_operation("group-two"),
          cash_operation("pay-1", "group-live", 12_000)
        ]
      )

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             results

    :ok
  end

  describe "moving held funding" do
    test "moves cash in reverse allocation order into the destination's original room order", %{
      conn: conn
    } do
      results =
        post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      assert [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "source_group_id" => "group-live",
                 "destination_group_id" => "group-two",
                 "amount_cents" => 5_000,
                 "source_outstanding_deposit_cents" => 12_500,
                 "destination_outstanding_deposit_cents" => 14_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = results

      # The removal comes off room-b's tail allocation first; what was drawn
      # fills group-two's room-a in draw order.
      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 7_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ],
                 "cash_paid_cents" => 7_000,
                 "outstanding_deposit_cents" => 12_500,
                 "revision" => 3
               }
             } = get_group!("group-live")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 5_000},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0}
                 ],
                 "cash_paid_cents" => 5_000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             } = get_group!("group-two")

      # A transfer changes no ledger total.
      assert %{"data" => %{"cash_held_cents" => 12_000}} = get_ledger!()
    end

    test "keeps provenance and evolves the payment statement with held_by_group", %{conn: conn} do
      # Before any transfer the statement keeps its earlier shape.
      statement = get_statement!("pay-1")["data"]
      assert map_size(statement) == 9
      refute Map.has_key?(statement, "held_by_group")

      post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      assert %{
               "data" => %{
                 "payment_operation_id" => "pay-1",
                 "original_group_id" => "group-live",
                 "recorded_cents" => 12_000,
                 "held_cents" => 12_000,
                 "held_by_group" => held_by_group
               }
             } = get_statement!("pay-1")

      assert held_by_group == [
               %{"group_id" => "group-live", "amount_cents" => 7_000},
               %{"group_id" => "group-two", "amount_cents" => 5_000}
             ]

      assert Enum.sum(Enum.map(held_by_group, & &1["amount_cents"])) == 12_000
    end

    test "transfers hotel credit keeping its lot, paused expiry, and original expiry on restore",
         %{
           conn: conn
         } do
      give_guest_credit(conn)

      post_batch(conn, [apply_credit_operation("op-apply", "group-live", 5_000)])

      results =
        post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      assert [%{"status" => "applied", "source_revision" => 4, "destination_revision" => 2}] =
               results

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "credit_paid_cents" => 0},
                   %{"room_id" => "room-b", "credit_paid_cents" => 0}
                 ]
               }
             } = get_group!("group-live")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "credit_paid_cents" => 5_000},
                   %{"room_id" => "room-b", "credit_paid_cents" => 0}
                 ]
               }
             } = get_group!("group-two")

      # Expiry stays paused while applied, so no liability change either way.
      assert %{"data" => %{"available_cents" => 3_800, "lots" => [lot]}} = guest_credit!()
      assert %{"remaining_cents" => 3_800, "expires_on" => "2027-11-27"} = lot

      # A refundable cancellation restores it to its original lot with its
      # original expiry and without another bonus.
      results = post_batch(conn, [cancel_operation("op-cancel-two", "group-two")])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] = results

      assert %{"data" => %{"available_cents" => 8_800, "lots" => [lot]}} = guest_credit!()

      assert %{"remaining_cents" => 8_800, "expires_on" => "2027-11-27"} = lot

      assert %{"data" => %{"credit_liability_cents" => 8_800}} = get_ledger!()
    end

    test "draws mixed funding across kinds in reverse allocation order preserving draw order", %{
      conn: conn
    } do
      give_guest_credit(conn)

      # group-live holds cash seq1/seq2 (9_000 + 3_000) and credit seq3
      # (4_000 into room-b's remaining capacity).
      post_batch(conn, [apply_credit_operation("op-apply", "group-live", 4_000)])

      results =
        post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 8_000)])

      assert [%{"status" => "applied"}] = results

      # Reverse allocation order draws the credit first, then room-b's cash,
      # then part of room-a's cash; the destination's room-a fills with those
      # units in exactly that order.
      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 8_000, "credit_paid_cents" => 0},
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ],
                 "cash_paid_cents" => 8_000,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 11_500
               }
             } = get_group!("group-live")

      assert %{
               "data" => %{
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 4_000,
                     "credit_paid_cents" => 4_000
                   },
                   %{"room_id" => "room-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
                 ],
                 "cash_paid_cents" => 4_000,
                 "credit_paid_cents" => 4_000,
                 "outstanding_deposit_cents" => 11_500
               }
             } = get_group!("group-two")

      assert %{"data" => %{"held_by_group" => held_by_group, "held_cents" => 12_000}} =
               get_statement!("pay-1")

      assert held_by_group == [
               %{"group_id" => "group-live", "amount_cents" => 8_000},
               %{"group_id" => "group-two", "amount_cents" => 4_000}
             ]

      # The transferred credit remains applied with expiry paused: the
      # liability still counts all 8_800.
      assert %{"data" => %{"credit_liability_cents" => 8_800}} = get_ledger!()
    end

    test "is durably idempotent like every other operation", %{conn: conn} do
      operation = transfer_operation("op-once", "group-live", "group-two", 5_000)

      expected = %{
        "operation_id" => "op-once",
        "status" => "applied",
        "source_group_id" => "group-live",
        "destination_group_id" => "group-two",
        "amount_cents" => 5_000,
        "source_outstanding_deposit_cents" => 12_500,
        "destination_outstanding_deposit_cents" => 14_500,
        "source_revision" => 3,
        "destination_revision" => 2
      }

      assert [^expected] = post_batch(conn, [operation])
      # The exact stored result replays without moving funding again.
      assert [^expected] = post_batch(conn, [operation])

      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 7_000}} =
               get_group!("group-live")

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 5_000}} =
               get_group!("group-two")

      conflicting = transfer_operation("op-once", "group-live", "group-two", 6_000)

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               post_batch(conn, [conflicting])
    end

    test "sees earlier operations of the same batch", %{conn: conn} do
      results =
        post_batch(conn, [
          transfer_operation("op-move", "group-live", "group-two", 5_000),
          cash_operation("pay-2", "group-two", 2_000)
        ])

      assert [%{"status" => "applied"}, %{"outstanding_deposit_cents" => 12_500}] = results

      # The transferred funding left room for the later payment.
      assert %{"data" => %{"rooms" => [%{"cash_paid_cents" => 7_000}, _]}} =
               get_group!("group-live")

      assert %{"data" => %{"cash_paid_cents" => 7_000, "outstanding_deposit_cents" => 12_500}} =
               get_group!("group-two")
    end
  end

  describe "transfer rejections" do
    test "rejects same-group and cross-guest transfers with invalid_transfer", %{conn: conn} do
      post_batch(conn, [open_operation("group-other", guest_id: "guest-99")])

      results =
        post_batch(conn, [
          transfer_operation("op-same", "group-live", "group-live", 1_000),
          transfer_operation("op-guest", "group-live", "group-other", 1_000)
        ])

      assert [
               %{"status" => "rejected", "code" => "invalid_transfer"},
               %{"status" => "rejected", "code" => "invalid_transfer"}
             ] = results

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 12_000}} =
               get_group!("group-live")
    end

    test "resolves source existence then destination existence with that group_id", %{conn: conn} do
      results =
        post_batch(conn, [
          transfer_operation("op-missing-source", "group-missing", "group-two", 1_000),
          transfer_operation("op-missing-dest", "group-live", "group-missing", 1_000)
        ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "group-missing"
               },
               %{
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "group-missing"
               }
             ] = results
    end

    test "names the inactive group with its group_id", %{conn: conn} do
      post_batch(conn, [
        cancel_operation("op-cancel-live", "group-live"),
        cancel_operation("op-cancel-two", "group-two")
      ])

      results =
        post_batch(conn, [
          transfer_operation("op-inactive-source", "group-live", "group-two", 1_000)
        ])

      assert [%{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-live"}] =
               results

      # Activity is checked before the amount rule, so an inactive source is
      # named even when the amount would be invalid too.
      results =
        post_batch(conn, [
          transfer_operation("op-inactive-and-zero", "group-live", "group-two", 0)
        ])

      assert [%{"code" => "group_not_active", "group_id" => "group-live"}] = results
    end

    test "checks the destination's activity after the source is validated active", %{conn: conn} do
      post_batch(conn, [cancel_operation("op-cancel-two", "group-two")])

      results =
        post_batch(conn, [
          transfer_operation("op-inactive-dest", "group-live", "group-two", 1_000)
        ])

      assert [
               %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-two"}
             ] = results
    end

    test "rejects non-positive amounts with invalid_amount", %{conn: conn} do
      results =
        post_batch(conn, [
          transfer_operation("op-zero", "group-live", "group-two", 0),
          transfer_operation("op-negative", "group-live", "group-two", -100),
          transfer_operation("op-not-an-integer", "group-live", "group-two", "100")
        ])

      assert [
               %{"code" => "invalid_amount"},
               %{"code" => "invalid_amount"},
               %{"code" => "invalid_amount"}
             ] = results

      # Nothing moved anywhere.
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 12_000}} =
               get_group!("group-live")
    end

    test "rejects amounts beyond held funding or destination outstanding", %{conn: conn} do
      # Leave only 500 outstanding on the destination.
      post_batch(conn, [cash_operation("pay-dest", "group-two", 19_000)])

      results =
        post_batch(conn, [
          transfer_operation("op-over-held", "group-live", "group-two", 20_000),
          transfer_operation("op-over-outstanding", "group-live", "group-two", 1_000)
        ])

      assert [
               %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"},
               %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"}
             ] = results

      # Nothing moved anywhere.
      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 12_000}} =
               get_group!("group-live")

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 19_000}} =
               get_group!("group-two")
    end

    test "missing data needed to apply the transfer is invalid_operation", %{conn: conn} do
      base = fn overrides ->
        Map.merge(
          %{
            "operation_id" => "op-struct",
            "type" => "transfer_deposit",
            "occurred_on" => @transfer_occurred_on,
            "source_group_id" => "group-live",
            "destination_group_id" => "group-two",
            "amount_cents" => 100
          },
          overrides
        )
      end

      results =
        post_batch(conn, [
          Map.delete(base.(%{}), "amount_cents") |> Map.put("operation_id", "op-no-amount"),
          Map.delete(base.(%{}), "source_group_id") |> Map.put("operation_id", "op-no-source"),
          Map.delete(base.(%{}), "destination_group_id")
          |> Map.put("operation_id", "op-no-dest"),
          base.(%{"destination_expected_revision" => 0})
          |> Map.put("operation_id", "op-bad-guard"),
          %{"operation_id" => "op-not-a-map"}
        ])

      codes = Enum.map(results, & &1["code"])

      assert codes == [
               "invalid_operation",
               "invalid_operation",
               "invalid_operation",
               "invalid_operation",
               "invalid_operation"
             ]
    end
  end

  describe "revision ordering" do
    test "reports a stale source revision against group-live", %{conn: conn} do
      stale =
        transfer_operation("op-stale-source", "group-live", "group-two", 1_000)
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

    test "a destination mismatch uses the destination's details", %{conn: conn} do
      stale =
        transfer_operation("op-stale-dest", "group-live", "group-two", 1_000)
        |> Map.put("destination_expected_revision", 5)

      results = post_batch(conn, [stale])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-two",
                 "expected_revision" => 5,
                 "actual_revision" => 1
               }
             ] = results
    end

    test "the source revision is checked before the destination revision", %{conn: conn} do
      stale =
        transfer_operation("op-stale-both", "group-live", "group-two", 1_000)
        |> Map.put("expected_revision", 1)
        |> Map.put("destination_expected_revision", 7)

      results = post_batch(conn, [stale])

      assert [%{"code" => "stale_revision", "group_id" => "group-live"}] = results
    end

    test "revisions are checked before the transfer rules", %{conn: conn} do
      stale_negative =
        transfer_operation("op-stale-negative", "group-live", "group-two", -100)
        |> Map.put("expected_revision", 1)

      missing_before_stale =
        transfer_operation("op-missing-stale", "group-missing", "group-two", 1_000)
        |> Map.put("expected_revision", 1)

      results = post_batch(conn, [stale_negative, missing_before_stale])

      assert [
               %{"code" => "stale_revision", "group_id" => "group-live"},
               %{"code" => "group_not_found", "group_id" => "group-missing"}
             ] = results
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination's policy and bonus", %{conn: conn} do
      post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      results =
        post_batch(conn, [
          cancel_operation("op-cancel-two", "group-two")
          |> Map.put("refund_method", "hotel_credit")
        ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] = results

      # The cash settled at group-two converted there with the standard bonus;
      # the payment's history follows its allocations wherever they went.
      assert %{"data" => %{"available_cents" => 5_500, "lots" => [lot]}} = guest_credit!()

      assert %{"remaining_cents" => 5_500} = lot

      assert %{
               "data" => %{
                 "held_cents" => 7_000,
                 "converted_to_credit_cents" => 5_000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0,
                 "held_by_group" => [%{"group_id" => "group-live", "amount_cents" => 7_000}]
               }
             } = get_statement!("pay-1")

      assert %{"data" => %{"cash_converted_to_credit_cents" => 5_000, "cash_held_cents" => 7_000}} =
               get_ledger!()
    end

    test "an empty list remains once none of a transferred payment is held", %{conn: conn} do
      post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      post_batch(conn, [
        cancel_operation("op-cancel-two", "group-two"),
        cancel_operation("op-cancel-live", "group-live")
      ])

      assert %{"data" => %{"held_cents" => 0, "held_by_group" => []}} = get_statement!("pay-1")
    end

    test "reductions follow allocations across groups and increment every changed group", %{
      conn: conn
    } do
      post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      results = post_batch(conn, [reduce_operation("op-reduce", "pay-1", 2_000)])

      # The newest allocation lives on group-two, so the reduction lands
      # there; the addressed original group still reports its own revision.
      assert [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-1",
                 "group_id" => "group-live",
                 "amount_cents" => 2_000,
                 "outstanding_deposit_cents" => 12_500,
                 "revision" => 4
               }
             ] = results

      # The unguarded destination group increments because its state changed.
      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 3_000}} =
               get_group!("group-two")

      assert %{
               "data" => %{
                 "held_cents" => 10_000,
                 "reduced_cents" => 2_000,
                 "held_by_group" => [
                   %{"group_id" => "group-live", "amount_cents" => 7_000},
                   %{"group_id" => "group-two", "amount_cents" => 3_000}
                 ]
               }
             } = get_statement!("pay-1")

      assert %{"data" => %{"cash_held_cents" => 10_000, "cash_reduced_cents" => 2_000}} =
               get_ledger!()
    end

    test "chargebacks remove held allocations wherever they currently fund rooms", %{conn: conn} do
      post_batch(conn, [transfer_operation("op-move", "group-live", "group-two", 5_000)])

      results = post_batch(conn, [charge_back_operation("op-cb", "pay-1")])

      assert [%{"status" => "applied", "charged_back_cents" => 12_000, "revision" => 4}] = results

      # Both groups reopened their deposits and advanced their revisions.
      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 0}} = get_group!("group-live")

      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 0}} = get_group!("group-two")

      assert %{
               "data" => %{
                 "held_by_group" => [],
                 "charged_back_cents" => 12_000,
                 "held_cents" => 0
               }
             } = get_statement!("pay-1")

      assert %{"data" => %{"cash_held_cents" => 0, "cash_charged_back_cents" => 12_000}} =
               get_ledger!()
    end
  end
end
