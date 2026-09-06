defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.{GroupReservation, PartnerOperation, Repo}

  describe "POST /api/v1/partner-batches" do
    test "requires an operations array", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_batch"}} =
               conn
               |> post(~p"/api/v1/partner-batches", %{})
               |> json_response(422)
    end

    test "opens a group, calculates each flexible room's rounded deposit, and reads it back", %{
      conn: conn
    } do
      operation =
        open_group("open-rounded", "rounded-group", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3}
          ]
        })

      assert %{"results" => [result]} = batch(conn, [operation]) |> json_response(200)

      assert result == %{
               "operation_id" => "open-rounded",
               "status" => "applied",
               "group_id" => "rounded-group",
               "deposit_due_cents" => 2,
               "revision" => 1
             }

      assert %{"data" => group} =
               conn
               |> get(~p"/api/v1/groups/rounded-group")
               |> json_response(200)

      assert group == %{
               "group_id" => "rounded-group",
               "guest_id" => "guest-22",
               "property_id" => "ams-canal",
               "revision" => 1,
               "booked_on" => "2026-10-03",
               "arrival_on" => "2026-12-10",
               "departure_on" => "2026-12-11",
               "rate_plan" => "flexible",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26",
               "status" => "active",
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "nightly_rate_cents" => 3,
                   "status" => "active",
                   "lodging_total_cents" => 3,
                   "deposit_due_cents" => 1,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "nightly_rate_cents" => 3,
                   "status" => "active",
                   "lodging_total_cents" => 3,
                   "deposit_due_cents" => 1,
                   "cash_paid_cents" => 0,
                   "credit_paid_cents" => 0
                 }
               ],
               "lodging_total_cents" => 6,
               "deposit_due_cents" => 2,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 2
             }
    end

    test "uses full lodging as the advance-purchase deposit and ignores expected_revision", %{
      conn: conn
    } do
      operation =
        open_group("open-advance", "advance-group", %{
          "expected_revision" => 99,
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })

      assert %{"results" => [%{"deposit_due_cents" => 45_000, "revision" => 1}]} =
               batch(conn, [operation]) |> json_response(200)
    end

    test "rejects duplicate group identifiers", %{conn: conn} do
      first = open_group("open-first", "duplicate-group")
      duplicate = open_group("open-duplicate", "duplicate-group")

      assert %{"results" => [_, result]} = batch(conn, [first, duplicate]) |> json_response(200)

      assert result == %{
               "operation_id" => "open-duplicate",
               "status" => "rejected",
               "code" => "group_already_exists",
               "group_id" => "duplicate-group"
             }
    end

    test "validates opening fields without creating a group", %{conn: conn} do
      invalid_stay = open_group("bad-stay", "bad-stay", %{"departure_on" => "2026-12-10"})

      invalid_rooms =
        open_group("bad-rooms", "bad-rooms", %{
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 1_000},
            %{"room_id" => "same", "nightly_rate_cents" => 1_000}
          ]
        })

      invalid_plan = open_group("bad-plan", "bad-plan", %{"rate_plan" => "weekend_magic"})

      assert %{"results" => results} =
               batch(conn, [invalid_stay, invalid_rooms, invalid_plan]) |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_stay",
               "invalid_rooms",
               "invalid_rate_plan"
             ]

      assert %{"error" => %{"code" => "group_not_found"}} =
               conn
               |> get(~p"/api/v1/groups/bad-stay")
               |> json_response(404)
    end

    test "processes a batch in order and continues after a rejected payment", %{conn: conn} do
      group = open_group("open-sequential", "sequential-group", %{"rooms" => [room(10_000)]})

      too_large_payment = %{
        "operation_id" => "pay-too-large",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "sequential-group",
        "amount_cents" => 6_001
      }

      valid_payment = %{
        "operation_id" => "pay-valid",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "sequential-group",
        "amount_cents" => 6_000
      }

      assert %{"results" => [opened, rejected, paid]} =
               batch(conn, [group, too_large_payment, valid_payment]) |> json_response(200)

      assert opened["revision"] == 1

      assert rejected == %{
               "operation_id" => "pay-too-large",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert paid == %{
               "operation_id" => "pay-valid",
               "status" => "applied",
               "group_id" => "sequential-group",
               "amount_cents" => 6_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 2
             }

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 6_000}} =
               conn
               |> get(~p"/api/v1/groups/sequential-group")
               |> json_response(200)

      assert ledger(conn) == %{
               "cash_held_cents" => 6_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "reschedules an active group without changing its length or price", %{conn: conn} do
      assert %{"results" => [_]} =
               batch(conn, [open_group("open-move", "move-group")]) |> json_response(200)

      move = %{
        "operation_id" => "move-group",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "move-group",
        "new_arrival_on" => "2026-12-20"
      }

      assert %{"results" => [result]} = batch(conn, [move]) |> json_response(200)

      assert result == %{
               "operation_id" => "move-group",
               "status" => "applied",
               "group_id" => "move-group",
               "new_arrival_on" => "2026-12-20",
               "new_departure_on" => "2026-12-23",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-12-06",
               "revision" => 2
             }

      assert %{"data" => group} =
               conn |> get(~p"/api/v1/groups/move-group") |> json_response(200)

      assert group["lodging_total_cents"] == 30_000
      assert group["deposit_due_cents"] == 6_000

      invalid_move = %{move | "operation_id" => "bad-move", "new_arrival_on" => "2026-10-04"}

      assert %{"results" => [%{"code" => "invalid_stay"}]} =
               batch(conn, [invalid_move]) |> json_response(200)
    end

    test "settles flexible cancellation according to calendar days and removes held cash", %{
      conn: conn
    } do
      assert %{"results" => [_]} =
               batch(conn, [open_group("open-refund", "refund-group")]) |> json_response(200)

      pay = %{
        "operation_id" => "pay-refund",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "refund-group",
        "amount_cents" => 2_000
      }

      cancel = %{
        "operation_id" => "cancel-refund",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "refund-group"
      }

      assert %{"results" => [_, result]} = batch(conn, [pay, cancel]) |> json_response(200)

      assert result == %{
               "operation_id" => "cancel-refund",
               "status" => "applied",
               "group_id" => "refund-group",
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2_000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }

      assert %{"data" => %{"status" => "cancelled", "outstanding_deposit_cents" => 0}} =
               conn
               |> get(~p"/api/v1/groups/refund-group")
               |> json_response(200)
    end

    test "retains late flexible and every advance-purchase cancellation payment", %{conn: conn} do
      flexible = open_group("open-late", "late-group")

      advance =
        open_group("open-advance-cancel", "advance-cancel", %{
          "rate_plan" => "advance_purchase",
          "rooms" => [room(20_000)]
        })

      payments = [
        %{
          "operation_id" => "pay-late",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "late-group",
          "amount_cents" => 2_000
        },
        %{
          "operation_id" => "pay-advance",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => "advance-cancel",
          "amount_cents" => 60_000
        }
      ]

      cancellations = [
        %{
          "operation_id" => "cancel-late",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "late-group"
        },
        %{
          "operation_id" => "cancel-advance",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-01",
          "group_id" => "advance-cancel"
        }
      ]

      assert %{"results" => _} =
               batch(conn, [flexible, advance] ++ payments ++ cancellations) |> json_response(200)

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 62_000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "enforces revisions before other domain validation and preserves state on stale writes",
         %{
           conn: conn
         } do
      assert %{"results" => [_]} =
               batch(conn, [open_group("open-revision", "revision-group")]) |> json_response(200)

      fresh_payment = %{
        "operation_id" => "fresh-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "revision-group",
        "amount_cents" => 1_000,
        "expected_revision" => 1
      }

      stale_invalid_payment = %{
        "operation_id" => "stale-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "not-a-date",
        "group_id" => "revision-group",
        "amount_cents" => -1,
        "expected_revision" => 1
      }

      missing_group = %{
        "operation_id" => "missing-revision",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "does-not-exist",
        "expected_revision" => 999
      }

      assert %{"results" => [_, stale, missing]} =
               batch(conn, [fresh_payment, stale_invalid_payment, missing_group])
               |> json_response(200)

      assert stale == %{
               "operation_id" => "stale-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "revision-group",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert missing == %{
               "operation_id" => "missing-revision",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "does-not-exist"
             }

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1_000}} =
               conn
               |> get(~p"/api/v1/groups/revision-group")
               |> json_response(200)
    end

    test "rejects later operations on a cancelled group without changing its revision", %{
      conn: conn
    } do
      open = open_group("open-cancelled", "cancelled-group")

      cancel = %{
        "operation_id" => "cancel-once",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "cancelled-group"
      }

      payment = %{
        "operation_id" => "pay-cancelled",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "cancelled-group",
        "amount_cents" => 1
      }

      assert %{"results" => [_, _, rejected]} =
               batch(conn, [open, cancel, payment]) |> json_response(200)

      assert rejected["code"] == "group_not_active"

      assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} =
               conn
               |> get(~p"/api/v1/groups/cancelled-group")
               |> json_response(200)
    end

    test "rejects unknown and unidentifiable operations while preserving later operations", %{
      conn: conn
    } do
      unknown = %{
        "operation_id" => "unknown",
        "type" => "swap_group",
        "occurred_on" => "2026-10-03"
      }

      missing_identifier = %{"operation_id" => "missing-group", "type" => "cancel_group"}
      valid = open_group("open-after-invalid", "after-invalid")

      assert %{"results" => [first, second, third]} =
               batch(conn, [unknown, missing_identifier, valid]) |> json_response(200)

      assert first["code"] == "invalid_operation"
      assert second["code"] == "invalid_operation"
      assert third["status"] == "applied"
    end

    test "assigns a fixed cancellation policy and recomputes its cutoff when rescheduled", %{
      conn: conn
    } do
      legacy = open_group("open-legacy-policy", "legacy-policy")

      current =
        open_group("open-current-policy", "current-policy", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-20",
          "departure_on" => "2027-03-22"
        })

      advance =
        open_group("open-advance-policy", "advance-policy", %{
          "rate_plan" => "advance_purchase"
        })

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"}
               ]
             } =
               batch(conn, [legacy, current, advance]) |> json_response(200)

      assert %{"data" => %{"policy_version" => "flex-14", "refundable_until" => "2026-11-26"}} =
               get(conn, ~p"/api/v1/groups/legacy-policy") |> json_response(200)

      assert %{
               "data" => %{"policy_version" => "advance-nonrefundable", "refundable_until" => nil}
             } =
               get(conn, ~p"/api/v1/groups/advance-policy") |> json_response(200)

      move = %{
        "operation_id" => "move-current-policy",
        "type" => "reschedule_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "current-policy",
        "new_arrival_on" => "2027-04-20"
      }

      assert %{"results" => [result]} = batch(conn, [move]) |> json_response(200)

      assert result == %{
               "operation_id" => "move-current-policy",
               "status" => "applied",
               "group_id" => "current-policy",
               "new_arrival_on" => "2027-04-20",
               "new_departure_on" => "2027-04-22",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-21",
               "revision" => 2
             }
    end

    test "derives the original policy when reading a legacy group without a stored version", %{
      conn: conn
    } do
      Repo.insert!(%GroupReservation{
        group_id: "legacy-stored-group",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-12-31],
        arrival_on: ~D[2027-02-20],
        departure_on: ~D[2027-02-21],
        rate_plan: "flexible",
        status: "active",
        lodging_total_cents: 10_000,
        deposit_due_cents: 2_000,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1
      })

      assert %{"data" => %{"policy_version" => "flex-14", "refundable_until" => "2027-02-06"}} =
               get(conn, ~p"/api/v1/groups/legacy-stored-group") |> json_response(200)
    end

    test "converts a refundable cancellation into bonus hotel credit and reports its liability",
         %{
           conn: conn
         } do
      pay = %{
        "operation_id" => "pay-credit-source",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-source",
        "amount_cents" => 5
      }

      cancel = %{
        "operation_id" => "cancel-to-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "credit-source",
        "refund_method" => "hotel_credit"
      }

      assert %{"results" => [_, _, result]} =
               batch(conn, [open_group("open-credit-source", "credit-source"), pay, cancel])
               |> json_response(200)

      assert result == %{
               "operation_id" => "cancel-to-credit",
               "status" => "applied",
               "group_id" => "credit-source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 6,
               "revision" => 3
             }

      assert credit(conn, "guest-22", "2026-11-26") == %{
               "guest_id" => "guest-22",
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-to-credit",
                   "remaining_cents" => 6,
                   "expires_on" => "2027-11-27"
                 }
               ]
             }

      assert ledger(conn, "2026-11-26") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "redeems credit by expiry and source identifier without changing its liability", %{
      conn: conn
    } do
      source_b =
        open_group("open-source-b", "source-b", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2026-12-31",
          "departure_on" => "2027-01-01"
        })

      source_a =
        open_group("open-source-a", "source-a", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2026-12-31",
          "departure_on" => "2027-01-01"
        })

      cash_payment = fn operation_id, group_id ->
        %{
          "operation_id" => operation_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-01-02",
          "group_id" => group_id,
          "amount_cents" => 100
        }
      end

      credit_cancellation = fn operation_id, group_id ->
        %{
          "operation_id" => operation_id,
          "type" => "cancel_group",
          "occurred_on" => "2026-01-02",
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        }
      end

      assert %{"results" => results} =
               batch(conn, [
                 source_b,
                 cash_payment.("pay-source-b", "source-b"),
                 credit_cancellation.("cancel-b", "source-b"),
                 source_a,
                 cash_payment.("pay-source-a", "source-a"),
                 credit_cancellation.("cancel-a", "source-a"),
                 open_group("open-credit-target", "credit-target", %{
                   "occurred_on" => "2026-01-01",
                   "arrival_on" => "2026-02-10",
                   "departure_on" => "2026-02-11",
                   "rooms" => [room(3_000)]
                 })
               ])
               |> json_response(200)

      assert Enum.all?(results, &(&1["status"] == "applied"))

      apply_credit = %{
        "operation_id" => "apply-ordered-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-02-01",
        "group_id" => "credit-target",
        "amount_cents" => 150
      }

      assert %{"results" => [result]} = batch(conn, [apply_credit]) |> json_response(200)

      assert result == %{
               "operation_id" => "apply-ordered-credit",
               "status" => "applied",
               "group_id" => "credit-target",
               "amount_cents" => 150,
               "outstanding_deposit_cents" => 450,
               "revision" => 2
             }

      assert credit(conn, "guest-22", "2026-02-01") == %{
               "guest_id" => "guest-22",
               "available_cents" => 70,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 70,
                   "expires_on" => "2027-01-03"
                 }
               ]
             }

      assert %{"data" => group} =
               get(conn, ~p"/api/v1/groups/credit-target") |> json_response(200)

      assert Map.take(group, [
               "cash_paid_cents",
               "credit_paid_cents",
               "deposit_paid_cents",
               "outstanding_deposit_cents"
             ]) == %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 150,
               "deposit_paid_cents" => 150,
               "outstanding_deposit_cents" => 450
             }

      assert ledger(conn, "2026-02-01") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 200,
               "credit_liability_cents" => 220,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "restores refundable credit before expiry and consumes it when restored after expiry", %{
      conn: conn
    } do
      source = open_group("open-expiring-source", "expiring-source")

      source_payment = %{
        "operation_id" => "pay-expiring-source",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "expiring-source",
        "amount_cents" => 100
      }

      source_cancellation = %{
        "operation_id" => "cancel-expiring-source",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "expiring-source",
        "refund_method" => "hotel_credit"
      }

      first_target =
        open_group("open-restore-target", "restore-target", %{
          "arrival_on" => "2026-12-20",
          "departure_on" => "2026-12-23"
        })

      first_redemption = %{
        "operation_id" => "apply-restorable-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "restore-target",
        "amount_cents" => 100
      }

      second_restorable_redemption = %{
        "operation_id" => "apply-more-restorable-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-27",
        "group_id" => "restore-target",
        "amount_cents" => 5
      }

      first_cancellation = %{
        "operation_id" => "cancel-restore-target",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-28",
        "group_id" => "restore-target"
      }

      assert %{"results" => results} =
               batch(conn, [
                 source,
                 source_payment,
                 source_cancellation,
                 first_target,
                 first_redemption,
                 second_restorable_redemption,
                 first_cancellation
               ])
               |> json_response(200)

      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert credit(conn, "guest-22", "2026-11-28")["available_cents"] == 110

      second_target =
        open_group("open-expired-restore-target", "expired-restore-target", %{
          "arrival_on" => "2027-12-20",
          "departure_on" => "2027-12-21"
        })

      second_redemption = %{
        "operation_id" => "apply-expiring-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-29",
        "group_id" => "expired-restore-target",
        "amount_cents" => 100
      }

      second_cancellation = %{
        "operation_id" => "cancel-expired-restore-target",
        "type" => "cancel_group",
        "occurred_on" => "2027-11-28",
        "group_id" => "expired-restore-target"
      }

      assert %{"results" => [_, redemption, cancellation]} =
               batch(conn, [second_target, second_redemption, second_cancellation])
               |> json_response(200)

      assert redemption["status"] == "applied"
      assert cancellation["status"] == "applied"
      assert credit(conn, "guest-22", "2027-11-28")["available_cents"] == 0
      assert ledger(conn, "2027-11-28")["credit_liability_cents"] == 0
    end

    test "rejects unavailable credit and hotel-credit refunds without advancing a revision", %{
      conn: conn
    } do
      target = open_group("open-credit-rejection", "credit-rejection")

      stale_credit = %{
        "operation_id" => "stale-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "not-a-date",
        "group_id" => "credit-rejection",
        "amount_cents" => 1,
        "expected_revision" => 0
      }

      insufficient_credit = %{
        "operation_id" => "insufficient-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "credit-rejection",
        "amount_cents" => 1
      }

      advance =
        open_group("open-nonref-credit", "nonref-credit", %{
          "rate_plan" => "advance_purchase"
        })

      unavailable_refund = %{
        "operation_id" => "cancel-nonref-to-credit",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "nonref-credit",
        "refund_method" => "hotel_credit"
      }

      assert %{"results" => [_, stale, insufficient, _, unavailable]} =
               batch(conn, [
                 target,
                 stale_credit,
                 insufficient_credit,
                 advance,
                 unavailable_refund
               ])
               |> json_response(200)

      assert stale == %{
               "operation_id" => "stale-credit",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "credit-rejection",
               "expected_revision" => 0,
               "actual_revision" => 1
             }

      assert unavailable == %{
               "operation_id" => "cancel-nonref-to-credit",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert insufficient == %{
               "operation_id" => "insufficient-credit",
               "status" => "rejected",
               "code" => "insufficient_credit"
             }

      assert %{"data" => %{"revision" => 1, "status" => "active"}} =
               get(conn, ~p"/api/v1/groups/nonref-credit") |> json_response(200)
    end
  end

  describe "durable operation idempotency" do
    test "replays an applied result verbatim without applying a later retry", %{conn: conn} do
      open = open_group("idempotent-open", "idempotent-group")

      payment = %{
        "operation_id" => "idempotent-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "idempotent-group",
        "amount_cents" => 1_000,
        "partner_context" => %{"sources" => ["gateway", "retry"]}
      }

      later_payment = %{payment | "operation_id" => "later-payment", "amount_cents" => 1_000}

      assert %{"results" => [_, original_result]} =
               batch(conn, [open, payment]) |> json_response(200)

      assert %{"results" => [%{"revision" => 3}]} =
               batch(conn, [later_payment]) |> json_response(200)

      assert %{"results" => [^original_result]} =
               batch(conn, [payment]) |> json_response(200)

      assert %{"data" => ^original_result} =
               get(conn, ~p"/api/v1/operations/idempotent-payment") |> json_response(200)

      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 2_000}} =
               get(conn, ~p"/api/v1/groups/idempotent-group") |> json_response(200)

      stored_operation = Repo.get_by!(PartnerOperation, operation_id: "idempotent-payment")

      assert stored_operation.operation_type == "record_cash_payment"
      assert stored_operation.payload == payment
      assert stored_operation.result == original_result

      assert Repo.get_by!(PartnerOperation, operation_id: "idempotent-open").id <
               stored_operation.id
    end

    test "remembers a rejection even when the operation would later have a different outcome", %{
      conn: conn
    } do
      open = open_group("open-rejected-retry", "rejected-retry-group")

      rejected_payment = %{
        "operation_id" => "rejected-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "rejected-retry-group",
        "amount_cents" => 6_001
      }

      cancel = %{
        "operation_id" => "cancel-rejected-retry-group",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "rejected-retry-group"
      }

      assert %{"results" => [_, original_rejection, _]} =
               batch(conn, [open, rejected_payment, cancel]) |> json_response(200)

      assert original_rejection == %{
               "operation_id" => "rejected-payment",
               "status" => "rejected",
               "code" => "payment_exceeds_outstanding"
             }

      assert %{"results" => [^original_rejection]} =
               batch(conn, [rejected_payment]) |> json_response(200)

      assert %{"data" => ^original_rejection} =
               get(conn, ~p"/api/v1/operations/rejected-payment") |> json_response(200)
    end

    test "rejects a reused identifier with a different payload without replacing its record", %{
      conn: conn
    } do
      open = open_group("open-conflicting-operation", "conflicting-operation-group")

      original_payment = %{
        "operation_id" => "conflicting-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "conflicting-operation-group",
        "amount_cents" => 100
      }

      changed_payment = %{original_payment | "amount_cents" => 101}

      assert %{"results" => [_, original_result]} =
               batch(conn, [open, original_payment]) |> json_response(200)

      assert %{"results" => [conflict]} = batch(conn, [changed_payment]) |> json_response(200)

      assert conflict == %{
               "operation_id" => "conflicting-payment",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert %{"results" => [^original_result]} =
               batch(conn, [original_payment]) |> json_response(200)

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
               get(conn, ~p"/api/v1/groups/conflicting-operation-group") |> json_response(200)
    end

    test "ignores JSON object key order but treats array order as part of a payload", %{
      conn: conn
    } do
      original =
        Jason.decode!(
          ~s({"operation_id":"json-shape","type":"unsupported","context":{"labels":["first","second"],"region":"ams"}})
        )

      equivalent =
        Jason.decode!(
          ~s({"context":{"region":"ams","labels":["first","second"]},"type":"unsupported","operation_id":"json-shape"})
        )

      changed_array =
        Jason.decode!(
          ~s({"operation_id":"json-shape","type":"unsupported","context":{"labels":["second","first"],"region":"ams"}})
        )

      assert %{"results" => [original_result]} = batch(conn, [original]) |> json_response(200)
      assert original_result["code"] == "invalid_operation"

      assert %{"results" => [^original_result]} =
               batch(conn, [equivalent]) |> json_response(200)

      assert %{"results" => [%{"code" => "operation_id_conflict"}]} =
               batch(conn, [changed_array]) |> json_response(200)
    end

    test "replays stale-revision details and treats a corrected revision as a conflict", %{
      conn: conn
    } do
      open = open_group("open-stale-retry", "stale-retry-group")

      fresh_payment = %{
        "operation_id" => "fresh-stale-retry-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "stale-retry-group",
        "amount_cents" => 100,
        "expected_revision" => 1
      }

      stale_payment = %{
        "operation_id" => "stale-retry-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "stale-retry-group",
        "amount_cents" => 100,
        "expected_revision" => 1
      }

      later_payment =
        fresh_payment
        |> Map.put("operation_id", "later-stale-retry-payment")
        |> Map.delete("expected_revision")

      corrected_stale_payment = %{stale_payment | "expected_revision" => 2}

      assert %{"results" => [_, _, original_stale_result]} =
               batch(conn, [open, fresh_payment, stale_payment]) |> json_response(200)

      assert original_stale_result == %{
               "operation_id" => "stale-retry-payment",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "stale-retry-group",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert %{"results" => [%{"revision" => 3}]} =
               batch(conn, [later_payment]) |> json_response(200)

      assert %{"results" => [^original_stale_result]} =
               batch(conn, [stale_payment]) |> json_response(200)

      assert %{"results" => [conflict]} =
               batch(conn, [corrected_stale_payment]) |> json_response(200)

      assert conflict["code"] == "operation_id_conflict"

      assert %{"data" => ^original_stale_result} =
               get(conn, ~p"/api/v1/operations/stale-retry-payment") |> json_response(200)
    end

    test "reports a missing remembered operation", %{conn: conn} do
      assert %{"error" => %{"code" => "operation_not_found"}} =
               get(conn, ~p"/api/v1/operations/does-not-exist") |> json_response(404)
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts with zero finance totals", %{conn: conn} do
      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end
  end

  describe "room accounting and payment corrections" do
    test "allocates cash across rooms and settles only the selected rooms", %{conn: conn} do
      open =
        open_group("open-room-accounting", "room-accounting", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-b", "nightly_rate_cents" => 20_000}
          ]
        })

      payment = %{
        "operation_id" => "pay-room-accounting",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "room-accounting",
        "amount_cents" => 3_000
      }

      cancel_rooms = %{
        "operation_id" => "cancel-one-room",
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-01",
        "group_id" => "room-accounting",
        "room_ids" => ["room-a"]
      }

      invalid_cancel = %{
        cancel_rooms
        | "operation_id" => "cancel-duplicate-room",
          "room_ids" => ["room-a", "room-a"]
      }

      assert %{"results" => [_, _, %{"code" => "invalid_rooms"}, settled]} =
               batch(conn, [open, payment, invalid_cancel, cancel_rooms]) |> json_response(200)

      assert settled == %{
               "operation_id" => "cancel-one-room",
               "status" => "applied",
               "group_id" => "room-accounting",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{"data" => group} =
               get(conn, ~p"/api/v1/groups/room-accounting") |> json_response(200)

      assert group["status"] == "active"

      assert Map.take(group, [
               "lodging_total_cents",
               "deposit_due_cents",
               "cash_paid_cents",
               "outstanding_deposit_cents"
             ]) == %{
               "lodging_total_cents" => 20_000,
               "deposit_due_cents" => 4_000,
               "cash_paid_cents" => 1_000,
               "outstanding_deposit_cents" => 3_000
             }

      assert group["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 10_000,
                 "status" => "cancelled",
                 "lodging_total_cents" => 10_000,
                 "deposit_due_cents" => 2_000,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 20_000,
                 "status" => "active",
                 "lodging_total_cents" => 20_000,
                 "deposit_due_cents" => 4_000,
                 "cash_paid_cents" => 1_000,
                 "credit_paid_cents" => 0
               }
             ]

      assert Map.take(ledger(conn), ["cash_held_cents", "cash_refunded_cents"]) == %{
               "cash_held_cents" => 1_000,
               "cash_refunded_cents" => 2_000
             }
    end

    test "reduces only held cash from its original payment and exposes a payment statement", %{
      conn: conn
    } do
      payment = %{
        "operation_id" => "pay-reduce-me",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "reduce-group",
        "amount_cents" => 2_000
      }

      reduce = %{
        "operation_id" => "reduce-payment",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-reduce-me",
        "amount_cents" => 500,
        "expected_revision" => 2
      }

      assert %{"results" => [_, original_payment, reduction]} =
               batch(conn, [
                 open_group("open-reduce", "reduce-group", %{"departure_on" => "2026-12-11"}),
                 payment,
                 reduce
               ])
               |> json_response(200)

      assert reduction == %{
               "operation_id" => "reduce-payment",
               "status" => "applied",
               "payment_operation_id" => "pay-reduce-me",
               "group_id" => "reduce-group",
               "amount_cents" => 500,
               "outstanding_deposit_cents" => 500,
               "revision" => 3
             }

      assert %{"results" => [same_reduction]} = batch(conn, [reduce]) |> json_response(200)
      assert same_reduction == reduction

      assert %{"data" => ^original_payment} =
               get(conn, ~p"/api/v1/operations/pay-reduce-me") |> json_response(200)

      assert %{"data" => statement} =
               get(conn, ~p"/api/v1/payments/pay-reduce-me") |> json_response(200)

      assert statement == %{
               "payment_operation_id" => "pay-reduce-me",
               "original_group_id" => "reduce-group",
               "recorded_cents" => 2_000,
               "held_cents" => 1_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 500,
               "charged_back_cents" => 0
             }

      exceeds = %{
        reduce
        | "operation_id" => "reduce-too-much",
          "amount_cents" => 1_501,
          "expected_revision" => 3
      }

      assert %{"results" => [%{"code" => "reduction_exceeds_held_cash"}]} =
               batch(conn, [exceeds]) |> json_response(200)

      complete_reduction = %{
        reduce
        | "operation_id" => "reduce-the-rest",
          "amount_cents" => 1_500,
          "expected_revision" => 3
      }

      assert %{"results" => [%{"outstanding_deposit_cents" => 2_000, "revision" => 4}]} =
               batch(conn, [complete_reduction]) |> json_response(200)

      assert %{"data" => %{"held_cents" => 0, "reduced_cents" => 2_000}} =
               get(conn, ~p"/api/v1/payments/pay-reduce-me") |> json_response(200)

      no_held_cash = %{
        complete_reduction
        | "operation_id" => "reduce-after-exhaustion",
          "amount_cents" => 1,
          "expected_revision" => 4
      }

      assert %{"results" => [%{"code" => "payment_not_reducible"}]} =
               batch(conn, [no_held_cash]) |> json_response(200)
    end

    test "charges back converted cash, tracks the credit shortfall, and preserves target revisions",
         %{
           conn: conn
         } do
      source_payment = %{
        "operation_id" => "pay-chargeback-source",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "chargeback-source",
        "amount_cents" => 1_000
      }

      source_cancel = %{
        "operation_id" => "cancel-chargeback-source",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "chargeback-source",
        "refund_method" => "hotel_credit"
      }

      apply_credit = %{
        "operation_id" => "apply-chargeback-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => "chargeback-target",
        "amount_cents" => 1_100
      }

      chargeback = %{
        "operation_id" => "charge-back-source-payment",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-chargeback-source",
        "expected_revision" => 3
      }

      target =
        open_group("open-chargeback-target", "chargeback-target", %{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [room(10_000)]
        })

      assert %{"results" => [_, _, _, _, _, charged_back]} =
               batch(conn, [
                 open_group("open-chargeback-source", "chargeback-source", %{
                   "departure_on" => "2026-12-11"
                 }),
                 source_payment,
                 source_cancel,
                 target,
                 apply_credit,
                 chargeback
               ])
               |> json_response(200)

      assert charged_back == %{
               "operation_id" => "charge-back-source-payment",
               "status" => "applied",
               "payment_operation_id" => "pay-chargeback-source",
               "group_id" => "chargeback-source",
               "charged_back_cents" => 1_000,
               "outstanding_deposit_cents" => 0,
               "revision" => 4
             }

      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 1_100}} =
               get(conn, ~p"/api/v1/groups/chargeback-target") |> json_response(200)

      assert Map.take(ledger(conn, "2026-11-02"), [
               "cash_converted_to_credit_cents",
               "cash_charged_back_cents",
               "credit_liability_cents",
               "credit_shortfall_cents"
             ]) == %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 1_000,
               "credit_liability_cents" => 1_100,
               "credit_shortfall_cents" => 1_100
             }

      assert %{"data" => %{"charged_back_cents" => 1_000, "converted_to_credit_cents" => 0}} =
               get(conn, ~p"/api/v1/payments/pay-chargeback-source") |> json_response(200)

      already_charged_back = %{
        chargeback
        | "operation_id" => "charge-back-again",
          "expected_revision" => 4
      }

      assert %{"results" => [%{"code" => "payment_not_chargeable"}]} =
               batch(conn, [already_charged_back]) |> json_response(200)
    end
  end

  describe "deposit transfers" do
    test "moves most-recent mixed funding between groups without changing ledger totals", %{
      conn: conn
    } do
      credit_source =
        open_group("open-transfer-credit-source", "transfer-credit-source", %{
          "departure_on" => "2026-12-11"
        })

      credit_payment = %{
        "operation_id" => "pay-transfer-credit-source",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-credit-source",
        "amount_cents" => 500
      }

      credit_cancellation = %{
        "operation_id" => "cancel-transfer-credit-source",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "transfer-credit-source",
        "refund_method" => "hotel_credit"
      }

      source =
        open_group("open-transfer-source", "transfer-source", %{
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "source-a", "nightly_rate_cents" => 5_000},
            %{"room_id" => "source-b", "nightly_rate_cents" => 5_000}
          ]
        })

      destination =
        open_group("open-transfer-destination", "transfer-destination", %{
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "destination-a", "nightly_rate_cents" => 5_000},
            %{"room_id" => "destination-b", "nightly_rate_cents" => 5_000}
          ]
        })

      source_payment = %{
        "operation_id" => "pay-transfer-source",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-source",
        "amount_cents" => 1_000
      }

      source_credit = %{
        "operation_id" => "apply-transfer-source-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => "transfer-source",
        "amount_cents" => 500
      }

      transfer = %{
        "operation_id" => "transfer-mixed-funding",
        "type" => "transfer_deposit",
        "source_group_id" => "transfer-source",
        "destination_group_id" => "transfer-destination",
        "amount_cents" => 700,
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      }

      assert %{"results" => [_, _, _, _, _, _, _]} =
               batch(conn, [
                 credit_source,
                 credit_payment,
                 credit_cancellation,
                 source,
                 destination,
                 source_payment,
                 source_credit
               ])
               |> json_response(200)

      before_transfer = ledger(conn, "2026-11-02")

      assert %{"results" => [result]} = batch(conn, [transfer]) |> json_response(200)

      assert result == %{
               "operation_id" => "transfer-mixed-funding",
               "status" => "applied",
               "source_group_id" => "transfer-source",
               "destination_group_id" => "transfer-destination",
               "amount_cents" => 700,
               "source_outstanding_deposit_cents" => 1_200,
               "destination_outstanding_deposit_cents" => 1_300,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert ledger(conn, "2026-11-02") == before_transfer

      assert %{"data" => source_group} =
               get(conn, ~p"/api/v1/groups/transfer-source") |> json_response(200)

      assert source_group["revision"] == 4

      assert source_group["rooms"]
             |> Enum.map(&Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])) == [
               %{"room_id" => "source-a", "cash_paid_cents" => 800, "credit_paid_cents" => 0},
               %{"room_id" => "source-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
             ]

      assert %{"data" => destination_group} =
               get(conn, ~p"/api/v1/groups/transfer-destination") |> json_response(200)

      assert destination_group["revision"] == 2

      assert destination_group["rooms"]
             |> Enum.map(&Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])) == [
               %{
                 "room_id" => "destination-a",
                 "cash_paid_cents" => 200,
                 "credit_paid_cents" => 500
               },
               %{"room_id" => "destination-b", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
             ]

      assert %{"results" => [^result]} = batch(conn, [transfer]) |> json_response(200)

      assert %{"data" => statement} =
               get(conn, ~p"/api/v1/payments/pay-transfer-source") |> json_response(200)

      assert statement["held_cents"] == 1_000

      assert statement["held_by_group"] == [
               %{"group_id" => "transfer-destination", "amount_cents" => 200},
               %{"group_id" => "transfer-source", "amount_cents" => 800}
             ]
    end

    test "settles transferred cash and credit under the destination group", %{conn: conn} do
      cash_source =
        open_group("open-settle-cash-source", "settle-cash-source", %{
          "departure_on" => "2026-12-11"
        })

      cash_destination =
        open_group("open-settle-cash-destination", "settle-cash-destination", %{
          "departure_on" => "2026-12-11"
        })

      cash_payment = %{
        "operation_id" => "pay-settle-transferred-cash",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "settle-cash-source",
        "amount_cents" => 1_000
      }

      cash_transfer = %{
        "operation_id" => "transfer-settled-cash",
        "type" => "transfer_deposit",
        "source_group_id" => "settle-cash-source",
        "destination_group_id" => "settle-cash-destination",
        "amount_cents" => 1_000
      }

      cash_cancellation = %{
        "operation_id" => "cancel-settled-cash-destination",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "settle-cash-destination",
        "refund_method" => "hotel_credit"
      }

      assert %{"results" => [_, _, _, transferred, cancelled]} =
               batch(conn, [
                 cash_source,
                 cash_destination,
                 cash_payment,
                 cash_transfer,
                 cash_cancellation
               ])
               |> json_response(200)

      assert transferred["source_revision"] == 3
      assert transferred["destination_revision"] == 2
      assert cancelled["credit_issued_cents"] == 1_100

      assert %{
               "data" => %{
                 "held_cents" => 0,
                 "converted_to_credit_cents" => 1_000,
                 "held_by_group" => []
               }
             } =
               get(conn, ~p"/api/v1/payments/pay-settle-transferred-cash") |> json_response(200)

      credit_source =
        open_group("open-settle-credit-source", "settle-credit-source", %{
          "departure_on" => "2026-12-11"
        })

      credit_origin =
        open_group("open-settle-credit-origin", "settle-credit-origin", %{
          "departure_on" => "2026-12-11"
        })

      credit_destination =
        open_group("open-settle-credit-destination", "settle-credit-destination", %{
          "departure_on" => "2026-12-11"
        })

      assert %{"results" => [_, _, _, _, _, _, _, cancellation]} =
               batch(conn, [
                 credit_source,
                 %{
                   "operation_id" => "pay-settle-credit-source",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "settle-credit-source",
                   "amount_cents" => 500
                 },
                 %{
                   "operation_id" => "cancel-settle-credit-source",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-01",
                   "group_id" => "settle-credit-source",
                   "refund_method" => "hotel_credit"
                 },
                 credit_origin,
                 credit_destination,
                 %{
                   "operation_id" => "apply-settle-transferred-credit",
                   "type" => "apply_hotel_credit",
                   "occurred_on" => "2026-11-02",
                   "group_id" => "settle-credit-origin",
                   "amount_cents" => 500
                 },
                 %{
                   "operation_id" => "transfer-settled-credit",
                   "type" => "transfer_deposit",
                   "source_group_id" => "settle-credit-origin",
                   "destination_group_id" => "settle-credit-destination",
                   "amount_cents" => 500
                 },
                 %{
                   "operation_id" => "cancel-settled-credit-destination",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-11-03",
                   "group_id" => "settle-credit-destination"
                 }
               ])
               |> json_response(200)

      assert Map.take(cancellation, ["refunded_cents", "retained_cents", "credit_issued_cents"]) ==
               %{
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }

      assert credit(conn, "guest-22", "2026-11-03")["available_cents"] == 1_650
    end

    test "validates transfer targets and revisions before changing either group", %{conn: conn} do
      source =
        open_group("open-transfer-validation-source", "transfer-validation-source", %{
          "departure_on" => "2026-12-11"
        })

      destination =
        open_group("open-transfer-validation-destination", "transfer-validation-destination", %{
          "departure_on" => "2026-12-11"
        })

      different_guest =
        open_group("open-transfer-different-guest", "transfer-different-guest", %{
          "guest_id" => "guest-elsewhere",
          "departure_on" => "2026-12-11"
        })

      assert %{
               "results" => [
                 _,
                 _,
                 _,
                 missing_source,
                 missing_destination,
                 same_group,
                 other_guest,
                 stale,
                 too_much
               ]
             } =
               batch(conn, [
                 source,
                 destination,
                 different_guest,
                 %{
                   "operation_id" => "transfer-missing-source",
                   "type" => "transfer_deposit",
                   "source_group_id" => "missing-source",
                   "destination_group_id" => "transfer-validation-destination",
                   "amount_cents" => 1
                 },
                 %{
                   "operation_id" => "transfer-missing-destination",
                   "type" => "transfer_deposit",
                   "source_group_id" => "transfer-validation-source",
                   "destination_group_id" => "missing-destination",
                   "amount_cents" => 1
                 },
                 %{
                   "operation_id" => "transfer-same-group",
                   "type" => "transfer_deposit",
                   "source_group_id" => "transfer-validation-source",
                   "destination_group_id" => "transfer-validation-source",
                   "amount_cents" => 1
                 },
                 %{
                   "operation_id" => "transfer-different-guest",
                   "type" => "transfer_deposit",
                   "source_group_id" => "transfer-validation-source",
                   "destination_group_id" => "transfer-different-guest",
                   "amount_cents" => 1
                 },
                 %{
                   "operation_id" => "transfer-stale-destination",
                   "type" => "transfer_deposit",
                   "source_group_id" => "transfer-validation-source",
                   "destination_group_id" => "transfer-validation-destination",
                   "amount_cents" => 0,
                   "expected_revision" => 1,
                   "destination_expected_revision" => 0
                 },
                 %{
                   "operation_id" => "transfer-too-much-held",
                   "type" => "transfer_deposit",
                   "source_group_id" => "transfer-validation-source",
                   "destination_group_id" => "transfer-validation-destination",
                   "amount_cents" => 1
                 }
               ])
               |> json_response(200)

      assert %{"data" => %{"revision" => 1, "cash_paid_cents" => 0}} =
               get(conn, ~p"/api/v1/groups/transfer-validation-source") |> json_response(200)

      assert missing_source == %{
               "operation_id" => "transfer-missing-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "missing-source"
             }

      assert missing_destination["group_id"] == "missing-destination"
      assert same_group["code"] == "invalid_transfer"
      assert other_guest["code"] == "invalid_transfer"

      assert stale == %{
               "operation_id" => "transfer-stale-destination",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "transfer-validation-destination",
               "expected_revision" => 0,
               "actual_revision" => 1
             }

      assert too_much["code"] == "transfer_exceeds_held_funding"
    end

    test "reductions and chargebacks follow held cash across transferred groups", %{conn: conn} do
      source =
        open_group("open-transfer-correction-source", "transfer-correction-source", %{
          "departure_on" => "2026-12-11",
          "rooms" => [room(5_000)]
        })

      destination =
        open_group("open-transfer-correction-destination", "transfer-correction-destination", %{
          "departure_on" => "2026-12-11",
          "rooms" => [room(5_000)]
        })

      payment = %{
        "operation_id" => "pay-transfer-correction",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "transfer-correction-source",
        "amount_cents" => 1_000
      }

      transfer = %{
        "operation_id" => "transfer-correction-funding",
        "type" => "transfer_deposit",
        "source_group_id" => "transfer-correction-source",
        "destination_group_id" => "transfer-correction-destination",
        "amount_cents" => 500
      }

      reduction = %{
        "operation_id" => "reduce-transferred-payment",
        "type" => "reduce_cash_payment",
        "payment_operation_id" => "pay-transfer-correction",
        "amount_cents" => 100,
        "expected_revision" => 3
      }

      assert %{"results" => [_, _, _, _, reduced]} =
               batch(conn, [source, destination, payment, transfer, reduction])
               |> json_response(200)

      assert reduced == %{
               "operation_id" => "reduce-transferred-payment",
               "status" => "applied",
               "payment_operation_id" => "pay-transfer-correction",
               "group_id" => "transfer-correction-source",
               "amount_cents" => 100,
               "outstanding_deposit_cents" => 500,
               "revision" => 4
             }

      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 500}} =
               get(conn, ~p"/api/v1/groups/transfer-correction-source") |> json_response(200)

      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 400}} =
               get(conn, ~p"/api/v1/groups/transfer-correction-destination") |> json_response(200)

      assert %{"data" => %{"held_by_group" => held_by_group}} =
               get(conn, ~p"/api/v1/payments/pay-transfer-correction") |> json_response(200)

      assert held_by_group == [
               %{"group_id" => "transfer-correction-destination", "amount_cents" => 400},
               %{"group_id" => "transfer-correction-source", "amount_cents" => 500}
             ]

      chargeback = %{
        "operation_id" => "charge-back-transferred-payment",
        "type" => "charge_back_payment",
        "payment_operation_id" => "pay-transfer-correction",
        "expected_revision" => 4
      }

      assert %{"results" => [charged_back]} = batch(conn, [chargeback]) |> json_response(200)

      assert charged_back["charged_back_cents"] == 900
      assert charged_back["revision"] == 5

      assert %{"data" => %{"cash_paid_cents" => 0, "revision" => 5}} =
               get(conn, ~p"/api/v1/groups/transfer-correction-source") |> json_response(200)

      assert %{"data" => %{"cash_paid_cents" => 0, "revision" => 4}} =
               get(conn, ~p"/api/v1/groups/transfer-correction-destination") |> json_response(200)
    end
  end

  describe "daily finance reporting" do
    test "validates availability and creates a durable opening position at the start operation",
         %{
           conn: conn
         } do
      assert %{"error" => %{"code" => "invalid_reporting_date"}} =
               get(conn, ~p"/api/v1/finance/daily-report") |> json_response(422)

      assert %{"error" => %{"code" => "report_not_available"}} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05") |> json_response(404)

      invalid_start = %{
        "operation_id" => "invalid-start-finance-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "not-a-date"
      }

      assert %{"results" => [%{"code" => "invalid_reporting_date"}]} =
               batch(conn, [invalid_start]) |> json_response(200)

      group =
        open_group("report-opening-group", "report-opening-group", %{"rooms" => [room(10_000)]})

      pre_start_payment = %{
        "operation_id" => "report-opening-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-08",
        "group_id" => "report-opening-group",
        "amount_cents" => 100
      }

      start = %{
        "operation_id" => "start-finance-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-05"
      }

      post_start_payment = %{
        "operation_id" => "report-post-start-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "report-opening-group",
        "amount_cents" => 20
      }

      assert %{"results" => [_, _, start_result, _]} =
               batch(conn, [group, pre_start_payment, start, post_start_payment])
               |> json_response(200)

      assert start_result == %{
               "operation_id" => "start-finance-reporting",
               "status" => "applied",
               "starts_on" => "2026-10-05"
             }

      assert %{"data" => report} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

      assert report == %{
               "date" => "2026-10-05",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 100,
                   "movements" => %{
                     "received_cents" => 20,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 120
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }

      assert %{"results" => [retry]} = batch(conn, [start]) |> json_response(200)
      assert retry == start_result

      second_start = %{
        "operation_id" => "start-finance-reporting-again",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-06"
      }

      assert %{"results" => [%{"code" => "reporting_already_started"}]} =
               batch(conn, [second_start]) |> json_response(200)
    end

    test "reports property transfers and later settlements on their posting dates", %{conn: conn} do
      start = %{
        "operation_id" => "start-transfer-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-05"
      }

      source =
        open_group("report-transfer-source-open", "report-transfer-source", %{
          "property_id" => "ams-canal",
          "rooms" => [room(10_000)]
        })

      destination =
        open_group("report-transfer-destination-open", "report-transfer-destination", %{
          "property_id" => "rotterdam-harbor",
          "rooms" => [room(10_000)]
        })

      payment = %{
        "operation_id" => "report-transfer-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-06",
        "group_id" => "report-transfer-source",
        "amount_cents" => 100
      }

      transfer = %{
        "operation_id" => "report-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => "report-transfer-source",
        "destination_group_id" => "report-transfer-destination",
        "amount_cents" => 40
      }

      cancel = %{
        "operation_id" => "report-transfer-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-07",
        "group_id" => "report-transfer-source"
      }

      assert %{"results" => results} =
               batch(conn, [start, source, destination, payment, transfer, cancel])
               |> json_response(200)

      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"cash" => cash}} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-06") |> json_response(200)

      assert cash == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   "received_cents" => 100,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 40,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 60
               },
               %{
                 "property_id" => "rotterdam-harbor",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 40,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 40
               }
             ]

      assert %{"data" => %{"cash" => cash}} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-07") |> json_response(200)

      refund = Enum.find(cash, &(&1["property_id"] == "ams-canal"))

      assert refund["property_id"] == "ams-canal"
      assert refund["movements"]["refunded_cents"] == 60
      assert refund["closing_held_cents"] == 0
    end

    test "derives unused-credit expiry without a partner operation on the expiry day", %{
      conn: conn
    } do
      start = %{
        "operation_id" => "start-credit-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-03"
      }

      group =
        open_group("report-credit-open", "report-credit-group", %{"rooms" => [room(10_000)]})

      payment = %{
        "operation_id" => "report-credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "report-credit-group",
        "amount_cents" => 100
      }

      cancellation = %{
        "operation_id" => "report-credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "report-credit-group",
        "refund_method" => "hotel_credit"
      }

      assert %{"results" => [_, _, _, cancellation_result]} =
               batch(conn, [start, group, payment, cancellation]) |> json_response(200)

      assert cancellation_result["credit_issued_cents"] == 110

      assert %{"data" => %{"lots" => [%{"expires_on" => expires_on}]}} =
               get(conn, ~p"/api/v1/guests/guest-22/credit?on=2026-10-05") |> json_response(200)

      assert %{"data" => report} =
               get(conn, ~p"/api/v1/finance/daily-report?date=#{expires_on}")
               |> json_response(200)

      assert report["credit"] == %{
               "opening_liability_cents" => 110,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 110,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }
    end

    test "publishes immutable closed reports and posts late operations to the first open day", %{
      conn: conn
    } do
      close_before_reporting = %{
        "operation_id" => "close-before-reporting",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-04"
      }

      assert %{"results" => [%{"code" => "invalid_period"}]} =
               batch(conn, [close_before_reporting]) |> json_response(200)

      start = %{
        "operation_id" => "start-period-close-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-03"
      }

      group =
        open_group("period-close-open", "period-close-group", %{
          "rooms" => [room(1_000)]
        })

      first_close = %{
        "operation_id" => "close-first-period",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-04"
      }

      assert %{"results" => [_, _, close_result]} =
               batch(conn, [start, group, first_close]) |> json_response(200)

      assert close_result == %{
               "operation_id" => "close-first-period",
               "status" => "applied",
               "period_end_on" => "2026-10-04"
             }

      assert %{"data" => closed_before_late_payment} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-04") |> json_response(200)

      assert closed_before_late_payment["status"] == "closed"

      assert closed_before_late_payment["late_adjustments"] == %{
               "cash" => [],
               "credit" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               }
             }

      assert %{"results" => [retry]} = batch(conn, [first_close]) |> json_response(200)
      assert retry == close_result

      assert %{"results" => [%{"code" => "invalid_period"}]} =
               batch(conn, [
                 %{
                   "operation_id" => "close-duplicate-cutoff",
                   "type" => "close_finance_period",
                   "period_end_on" => "2026-10-04"
                 }
               ])
               |> json_response(200)

      late_payment = %{
        "operation_id" => "period-close-late-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "period-close-group",
        "amount_cents" => 100
      }

      open_period_payment = %{
        "operation_id" => "period-close-open-period-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-06",
        "group_id" => "period-close-group",
        "amount_cents" => 50
      }

      assert %{"results" => [%{"status" => "applied"}, %{"status" => "applied"}]} =
               batch(conn, [late_payment, open_period_payment]) |> json_response(200)

      assert %{"data" => late_report} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

      assert late_report["status"] == "open"

      assert late_report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 100
               }
             ]

      assert late_report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   "received_cents" => 100,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 }
               }
             ]

      assert %{"data" => open_period_report} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-06") |> json_response(200)

      assert open_period_report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 100,
                 "movements" => %{
                   "received_cents" => 50,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 150
               }
             ]

      assert open_period_report["late_adjustments"]["cash"] == []

      second_close = %{
        "operation_id" => "close-second-period",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-06"
      }

      assert %{"results" => [%{"status" => "applied"}]} =
               batch(conn, [second_close]) |> json_response(200)

      assert %{"data" => closed_late_report} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

      assert closed_late_report == Map.put(late_report, "status", "closed")

      assert %{"results" => [%{"status" => "applied"}]} =
               batch(conn, [
                 %{
                   "operation_id" => "period-close-later-late-payment",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-03",
                   "group_id" => "period-close-group",
                   "amount_cents" => 25
                 }
               ])
               |> json_response(200)

      assert %{"data" => closed_late_report_after_later_operation} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

      assert closed_late_report_after_later_operation == closed_late_report
    end

    test "keeps signed late chargeback classifications and late credit issuance visible", %{
      conn: conn
    } do
      start = %{
        "operation_id" => "start-late-classification-reporting",
        "type" => "start_finance_reporting",
        "starts_on" => "2026-10-03"
      }

      refunded_group =
        open_group("open-late-refund-group", "late-refund-group", %{"rooms" => [room(1_000)]})

      refunded_payment = %{
        "operation_id" => "late-refund-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "late-refund-group",
        "amount_cents" => 100
      }

      refund = %{
        "operation_id" => "late-refund-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "late-refund-group"
      }

      close = %{
        "operation_id" => "close-late-classification-period",
        "type" => "close_finance_period",
        "period_end_on" => "2026-10-04"
      }

      assert %{"results" => results} =
               batch(conn, [start, refunded_group, refunded_payment, refund, close])
               |> json_response(200)

      assert Enum.all?(results, &(&1["status"] == "applied"))

      chargeback = %{
        "operation_id" => "late-refund-chargeback",
        "type" => "charge_back_payment",
        "payment_operation_id" => "late-refund-payment",
        "expected_revision" => 3
      }

      credit_group =
        open_group("open-late-credit-group", "late-credit-group", %{"rooms" => [room(1_000)]})

      credit_payment = %{
        "operation_id" => "late-credit-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "late-credit-group",
        "amount_cents" => 100
      }

      credit_cancellation = %{
        "operation_id" => "late-credit-cancellation",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "late-credit-group",
        "refund_method" => "hotel_credit"
      }

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 cancellation
               ]
             } =
               batch(conn, [chargeback, credit_group, credit_payment, credit_cancellation])
               |> json_response(200)

      assert cancellation["credit_issued_cents"] == 110

      assert %{"data" => report} =
               get(conn, ~p"/api/v1/finance/daily-report?date=2026-10-05") |> json_response(200)

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   "received_cents" => 100,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => -100,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 100,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 100
                 }
               }
             ]

      assert report["late_adjustments"]["credit"] == %{
               "issued_cents" => 110,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }
    end
  end

  defp batch(conn, operations),
    do: post(conn, ~p"/api/v1/partner-batches", %{"operations" => operations})

  defp ledger(conn) do
    conn
    |> get(~p"/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn, on_date) do
    conn
    |> get(~p"/api/v1/ledger?on=#{on_date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, guest_id, on_date) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit?on=#{on_date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_group(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [room(10_000)]
      },
      overrides
    )
  end

  defp room(nightly_rate_cents),
    do: %{"room_id" => "room-a", "nightly_rate_cents" => nightly_rate_cents}
end
