defmodule GroupStayWeb.ApiControllerTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.{OperationRecord, Repo}

  describe "POST /api/v1/partner-batches" do
    test "rejects a body without an operations array", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => nil})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})
    end

    test "opens a group and rounds each flexible room deposit separately", %{conn: conn} do
      operation =
        open_operation(%{
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "room-a", "nightly_rate_cents" => 3},
            %{"room_id" => "room-b", "nightly_rate_cents" => 3}
          ]
        })

      assert [result] = submit(conn, [operation])

      assert result == %{
               "operation_id" => "op-open",
               "status" => "applied",
               "group_id" => "group-1",
               "deposit_due_cents" => 2,
               "revision" => 1
             }

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-1",
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
                 "deposit_paid_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 2
               }
             } = json_response(conn, 200)
    end

    test "uses the full lodging total for advance purchase", %{conn: conn} do
      operation =
        open_operation(%{
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })

      assert [%{"deposit_due_cents" => 45_000, "revision" => 1}] = submit(conn, [operation])
    end

    test "returns stable opening validation errors and does not create rejected groups", %{
      conn: conn
    } do
      operations = [
        open_operation(%{"operation_id" => "bad-stay", "departure_on" => "2026-12-10"}),
        open_operation(%{"operation_id" => "bad-rooms", "group_id" => "group-2", "rooms" => []}),
        open_operation(%{
          "operation_id" => "duplicate-rooms",
          "group_id" => "group-3",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        }),
        open_operation(%{
          "operation_id" => "bad-plan",
          "group_id" => "group-4",
          "rate_plan" => "breakfast"
        }),
        Map.delete(
          open_operation(%{"operation_id" => "missing", "group_id" => "group-5"}),
          "rooms"
        )
      ]

      assert results = submit(conn, operations)

      assert Enum.map(results, &{&1["operation_id"], &1["code"]}) == [
               {"bad-stay", "invalid_stay"},
               {"bad-rooms", "invalid_rooms"},
               {"duplicate-rooms", "invalid_rooms"},
               {"bad-plan", "invalid_rate_plan"},
               {"missing", "invalid_operation"}
             ]

      assert Enum.all?(results, &(&1["status"] == "rejected"))

      assert json_response(get(build_conn(), "/api/v1/groups/group-1"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "processes operations in order and continues after rejections", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay-1", 10_000, 1),
        payment_operation("too-much", 10_000, 2),
        payment_operation("pay-2", 9500, 2),
        open_operation(%{"operation_id" => "duplicate"}),
        %{"operation_id" => "unknown", "type" => "do_something"},
        "not-an-operation"
      ]

      assert [opened, paid, excessive, paid_again, duplicate, unknown, malformed] =
               submit(conn, operations)

      assert opened["revision"] == 1

      assert paid == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 10_000,
               "outstanding_deposit_cents" => 9500,
               "revision" => 2
             }

      assert excessive["code"] == "payment_exceeds_outstanding"
      assert paid_again["revision"] == 3
      assert paid_again["outstanding_deposit_cents"] == 0
      assert duplicate["code"] == "group_already_exists"
      assert unknown["code"] == "invalid_operation"

      assert malformed == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert %{
               "revision" => 3,
               "deposit_paid_cents" => 19_500,
               "outstanding_deposit_cents" => 0
             } = group_data("group-1")
    end

    test "validates payment amounts without changing state", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("zero", 0),
        payment_operation("negative", -1),
        Map.delete(payment_operation("missing", 1), "amount_cents"),
        payment_operation("valid", 1000)
      ]

      assert [_opened, zero, negative, missing, valid] = submit(conn, operations)

      assert zero["code"] == "invalid_amount"
      assert negative["code"] == "invalid_amount"
      assert missing["code"] == "invalid_operation"
      assert valid["revision"] == 2
      assert group_data("group-1")["deposit_paid_cents"] == 1000
    end

    test "resolves existence and stale revisions before other domain rules", %{conn: conn} do
      operations = [
        payment_operation("missing", -1, 999) |> Map.put("group_id", "absent"),
        open_operation(),
        payment_operation("stale-payment", -1, 0),
        reschedule_operation("stale-reschedule", "not-a-date", 0),
        cancel_operation("cancel", "2026-10-03", 1),
        payment_operation("stale-inactive", 1, 1),
        payment_operation("inactive", 1, 2)
      ]

      assert [
               missing,
               _opened,
               stale_payment,
               stale_reschedule,
               cancelled,
               stale_inactive,
               inactive
             ] =
               submit(conn, operations)

      assert missing["code"] == "group_not_found"

      for stale <- [stale_payment, stale_reschedule, stale_inactive] do
        assert stale["code"] == "stale_revision"
        assert stale["group_id"] == "group-1"
      end

      assert stale_payment["expected_revision"] == 0
      assert stale_payment["actual_revision"] == 1
      assert cancelled["revision"] == 2
      assert stale_inactive["actual_revision"] == 2
      assert inactive["code"] == "group_not_active"
      assert group_data("group-1")["revision"] == 2
    end

    test "only one concurrent operation can apply at an expected revision", %{conn: conn} do
      assert [%{"status" => "applied"}] = submit(conn, [open_operation()])

      results =
        ["concurrent-1", "concurrent-2"]
        |> Enum.map(fn operation_id ->
          Task.async(fn ->
            [result] =
              GroupStay.Operations.submit_batch([
                payment_operation(operation_id, 1000, 1)
              ])

            result
          end)
        end)
        |> Task.await_many()

      assert Enum.sort(Enum.map(results, & &1.status)) == ["applied", "rejected"]

      assert %{code: "stale_revision", expected_revision: 1, actual_revision: 2} =
               Enum.find(results, &(&1.status == "rejected"))

      assert %{
               "revision" => 2,
               "deposit_paid_cents" => 1000,
               "outstanding_deposit_cents" => 18_500
             } = group_data("group-1")
    end

    test "concurrent retries have only one effect and return the same result", %{conn: conn} do
      assert [%{"status" => "applied"}] = submit(conn, [open_operation()])
      operation = payment_operation("concurrent-retry", 1000, 1)

      results =
        1..2
        |> Enum.map(fn _index ->
          Task.async(fn ->
            [result] = GroupStay.Operations.submit_batch([operation])
            result |> Jason.encode!() |> Jason.decode!()
          end)
        end)
        |> Task.await_many()

      assert [first_result, second_result] = results
      assert second_result == first_result
      assert first_result["status"] == "applied"
      assert first_result["revision"] == 2
      assert group_data("group-1")["deposit_paid_cents"] == 1000

      assert Repo.aggregate(
               from(record in OperationRecord,
                 where: record.operation_id == "concurrent-retry"
               ),
               :count
             ) == 1
    end

    test "reschedules by preserving the stay length and all financial values", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay", 5000),
        reschedule_operation("not-after", "2026-10-05", 2, "2026-10-05"),
        reschedule_operation("move", "2027-01-30", 2)
      ]

      assert [_opened, _paid, invalid, moved] = submit(conn, operations)

      assert invalid["code"] == "invalid_stay"

      assert moved == %{
               "operation_id" => "move",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2027-01-30",
               "new_departure_on" => "2027-02-02",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-01-16",
               "revision" => 3
             }

      assert %{
               "arrival_on" => "2027-01-30",
               "departure_on" => "2027-02-02",
               "lodging_total_cents" => 97_500,
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 5000
             } = group_data("group-1")
    end

    test "refunds flexible cash exactly fourteen days before arrival", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation("pay", 5000),
        cancel_operation("cancel", "2026-11-26", 2)
      ]

      assert [_opened, _paid, cancelled] = submit(conn, operations)

      assert cancelled == %{
               "operation_id" => "cancel",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 5000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "status" => "cancelled",
               "deposit_due_cents" => 0,
               "deposit_paid_cents" => 0,
               "outstanding_deposit_cents" => 0
             } = group_data("group-1")

      assert ledger_data() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "retains late flexible and all advance-purchase cash", %{conn: conn} do
      late_flexible = [
        open_operation(),
        payment_operation("flex-pay", 1000),
        cancel_operation("flex-cancel", "2026-11-27", 2),
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "group-2",
          "rate_plan" => "advance_purchase"
        }),
        payment_operation("advance-pay", 2000, 1) |> Map.put("group_id", "group-2"),
        cancel_operation("advance-cancel", "2026-10-03", 2) |> Map.put("group_id", "group-2")
      ]

      assert [_open, _pay, flex_cancel, _open_advance, _advance_pay, advance_cancel] =
               submit(conn, late_flexible)

      assert flex_cancel["retained_cents"] == 1000
      assert flex_cancel["refunded_cents"] == 0
      assert advance_cancel["retained_cents"] == 2000

      assert ledger_data() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3000,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "fixes the cancellation policy at booking across the cutoff", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "new-flex",
          "group_id" => "new-flex",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13"
        }),
        open_operation(%{
          "operation_id" => "advance",
          "group_id" => "advance",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-13",
          "rate_plan" => "advance_purchase"
        })
      ]

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = submit(conn, operations)

      assert %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-02-08"
             } = group_data("new-flex")

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = group_data("advance")

      results =
        submit(build_conn(), [
          payment_operation("pay-new", 1000, 1)
          |> Map.put("group_id", "new-flex")
          |> Map.put("occurred_on", "2027-01-02"),
          cancel_operation("cancel-new", "2027-02-08", 2)
          |> Map.put("group_id", "new-flex")
        ])

      assert [_payment, %{"refunded_cents" => 1000, "retained_cents" => 0}] = results
    end

    test "converts refundable cash to credit and restores applied credit without a bonus", %{
      conn: conn
    } do
      assert [_opened, _paid, converted] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 5000, 1),
                 cancel_operation("credit-source", "2026-11-26", 2, "hotel_credit")
               ])

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             } = converted

      assert guest_credit_data("guest-1", "2027-11-26") == %{
               "guest_id" => "guest-1",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-source",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert guest_credit_data("guest-1", "2027-11-27")["available_cents"] == 0

      assert [_opened, applied] =
               submit(build_conn(), [
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "occurred_on" => "2026-12-01",
                   "arrival_on" => "2027-03-10",
                   "departure_on" => "2027-03-13"
                 }),
                 credit_operation("apply", "destination", 5000, "2026-12-02", 1)
               ])

      assert %{
               "amount_cents" => 5000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             } = applied

      assert %{
               "deposit_paid_cents" => 5000,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 5000
             } = group_data("destination")

      assert %{
               "cash_converted_to_credit_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "credit_liability_cents" => 5500
             } = ledger_data("2027-01-01")

      assert [restored] =
               submit(build_conn(), [
                 cancel_operation("cancel-destination", "2027-02-24", 2)
                 |> Map.put("group_id", "destination")
               ])

      assert %{"credit_issued_cents" => 0, "refunded_cents" => 0, "retained_cents" => 0} =
               restored

      assert guest_credit_data("guest-1", "2027-02-24")["available_cents"] == 5500
      assert ledger_data("2027-02-24")["credit_liability_cents"] == 5500
    end

    test "pauses applied credit expiry and expires it when restored after its original date", %{
      conn: conn
    } do
      submit(conn, [
        open_operation(),
        payment_operation("pay", 1000, 1),
        cancel_operation("source", "2026-11-26", 2, "hotel_credit")
      ])

      assert [_opened, %{"status" => "applied"}] =
               submit(build_conn(), [
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "occurred_on" => "2026-12-01",
                   "arrival_on" => "2027-12-20",
                   "departure_on" => "2027-12-23"
                 }),
                 credit_operation("apply", "destination", 1100, "2027-11-26", 1)
               ])

      assert ledger_data("2028-01-01")["credit_liability_cents"] == 1100

      assert [%{"status" => "applied"}] =
               submit(build_conn(), [
                 cancel_operation("cancel-destination", "2027-12-01", 2)
                 |> Map.put("group_id", "destination")
               ])

      assert guest_credit_data("guest-1", "2027-12-01")["available_cents"] == 0
      assert ledger_data("2027-12-01")["credit_liability_cents"] == 0
    end

    test "keeps credit with a five-digit expiry available through the requested date", %{
      conn: conn
    } do
      assert [_opened, _paid, %{"credit_issued_cents" => 1100}] =
               submit(conn, [
                 open_operation(%{
                   "occurred_on" => "9999-01-01",
                   "arrival_on" => "9999-12-30",
                   "departure_on" => "9999-12-31"
                 }),
                 payment_operation("pay", 1000, 1)
                 |> Map.put("occurred_on", "9999-01-02"),
                 cancel_operation("source", "9999-11-30", 2, "hotel_credit")
               ])

      assert guest_credit_data("guest-1", "9999-12-31") == %{
               "guest_id" => "guest-1",
               "available_cents" => 1100,
               "lots" => [
                 %{
                   "source_operation_id" => "source",
                   "remaining_cents" => 1100,
                   "expires_on" => "10000-11-29"
                 }
               ]
             }

      assert ledger_data("9999-12-31")["credit_liability_cents"] == 1100
    end

    test "rejects hotel credit for non-refundable cancellation and consumes credit on cash settlement",
         %{
           conn: conn
         } do
      submit(conn, [
        open_operation(),
        payment_operation("source-pay", 1000, 1),
        cancel_operation("source", "2026-11-26", 2, "hotel_credit")
      ])

      assert [_opened, _cash, _credit, stale, unavailable] =
               submit(build_conn(), [
                 open_operation(%{
                   "operation_id" => "open-advance",
                   "group_id" => "advance",
                   "guest_id" => "guest-1",
                   "rate_plan" => "advance_purchase"
                 }),
                 payment_operation("cash", 500, 1) |> Map.put("group_id", "advance"),
                 credit_operation("credit", "advance", 1000, "2026-11-27", 2),
                 cancel_operation("stale", "2026-11-28", 2, "hotel_credit")
                 |> Map.put("group_id", "advance"),
                 cancel_operation("unavailable", "2026-11-28", 3, "hotel_credit")
                 |> Map.put("group_id", "advance")
               ])

      assert stale["code"] == "stale_revision"
      assert unavailable["code"] == "refund_method_not_available"
      assert %{"status" => "active", "revision" => 3} = group_data("advance")

      assert [cancelled] =
               submit(build_conn(), [
                 cancel_operation("settle", "2026-11-28", 3)
                 |> Map.put("group_id", "advance")
               ])

      assert %{
               "refunded_cents" => 0,
               "retained_cents" => 500,
               "credit_issued_cents" => 0
             } = cancelled

      assert %{
               "cash_retained_cents" => 500,
               "cash_converted_to_credit_cents" => 1000,
               "credit_liability_cents" => 100
             } = ledger_data("2026-11-28")
    end

    test "consumes available lots by expiry and source operation identifier", %{conn: conn} do
      for {group_id, source_id, amount} <- [
            {"group-z", "z-source", 1000},
            {"group-a", "a-source", 2000}
          ] do
        submit(conn, [
          open_operation(%{"operation_id" => "open-#{group_id}", "group_id" => group_id}),
          payment_operation("pay-#{group_id}", amount, 1) |> Map.put("group_id", group_id),
          cancel_operation(source_id, "2026-11-26", 2, "hotel_credit")
          |> Map.put("group_id", group_id)
        ])
      end

      assert Enum.map(guest_credit_data("guest-1", "2026-11-27")["lots"], fn lot ->
               lot["source_operation_id"]
             end) == ["a-source", "z-source"]

      assert [_opened, _applied] =
               submit(build_conn(), [
                 open_operation(%{
                   "operation_id" => "open-target",
                   "group_id" => "target",
                   "occurred_on" => "2026-11-27"
                 }),
                 credit_operation("apply", "target", 2500, "2026-11-27", 1)
               ])

      assert guest_credit_data("guest-1", "2026-11-27")["lots"] == [
               %{
                 "source_operation_id" => "z-source",
                 "remaining_cents" => 800,
                 "expires_on" => "2027-11-26"
               }
             ]
    end

    test "validates credit applications without advancing the revision", %{conn: conn} do
      assert [_opened, stale, invalid, excessive, insufficient] =
               submit(conn, [
                 open_operation(),
                 credit_operation("stale", "group-1", 0, "2026-10-04", 0),
                 credit_operation("invalid", "group-1", 0, "2026-10-04", 1),
                 credit_operation("excessive", "group-1", 20_000, "2026-10-04", 1),
                 credit_operation("insufficient", "group-1", 1000, "2026-10-04", 1)
               ])

      assert stale["code"] == "stale_revision"
      assert invalid["code"] == "invalid_amount"
      assert excessive["code"] == "payment_exceeds_outstanding"
      assert insufficient["code"] == "insufficient_credit"
      assert group_data("group-1")["revision"] == 1
    end

    test "replays an applied result without repeating its effects", %{conn: conn} do
      operation = open_operation()

      assert [original, replayed] = submit(conn, [operation, operation])
      assert replayed == original

      assert [%{"revision" => 2}] =
               submit(build_conn(), [payment_operation("pay", 1000, 1)])

      assert [payment, payment_replay] =
               submit(build_conn(), [
                 payment_operation("pay-replay", 2000, 2),
                 payment_operation("pay-replay", 2000, 2)
               ])

      assert payment_replay == payment

      assert %{
               "revision" => 3,
               "deposit_paid_cents" => 3000,
               "outstanding_deposit_cents" => 16_500
             } = group_data("group-1")

      assert Repo.aggregate(OperationRecord, :count) == 3
    end

    test "remembers rejections and rejects a changed retry payload", %{conn: conn} do
      missing = payment_operation("remembered-missing", 1000, 7) |> Map.put("group_id", "later")

      assert [%{"code" => "group_not_found"} = original] = submit(conn, [missing])

      assert [%{"status" => "applied"}] =
               submit(build_conn(), [open_operation(%{"group_id" => "later"})])

      assert [replayed] = submit(build_conn(), [missing])
      assert replayed == original

      corrected = Map.put(missing, "expected_revision", 1)

      assert [%{"code" => "operation_id_conflict"}] = submit(build_conn(), [corrected])
      assert [replayed_again] = submit(build_conn(), [missing])
      assert replayed_again == original

      assert json_response(get(build_conn(), "/api/v1/operations/remembered-missing"), 200) == %{
               "data" => original
             }
    end

    test "treats object order as irrelevant and array order as significant", %{conn: conn} do
      operation = open_operation(%{"extra" => %{"number" => 1}})
      reordered = operation |> Enum.reverse() |> Map.new()
      equivalent_number = put_in(reordered, ["extra", "number"], 1.0)

      assert [original] = submit(conn, [operation])
      assert [replayed] = submit(build_conn(), [equivalent_number])
      assert replayed == original

      changed = Map.update!(operation, "rooms", &Enum.reverse/1)

      assert [%{"code" => "operation_id_conflict"}] = submit(build_conn(), [changed])

      assert Enum.map(
               group_data("group-1")["rooms"],
               &Map.take(&1, ["room_id", "nightly_rate_cents"])
             ) ==
               operation["rooms"]
    end

    test "retains complete submissions, result type, and first-commit order", %{conn: conn} do
      first =
        open_operation(%{
          "extra" => %{"nested" => [1, %{"kept" => true}]}
        })

      second = %{"operation_id" => "unknown", "type" => "future_operation", "value" => 4}

      assert [%{"status" => "applied"}, %{"code" => "invalid_operation"}] =
               submit(conn, [first, second])

      records = Repo.all(from record in OperationRecord, order_by: record.commit_order)

      assert Enum.map(records, & &1.operation_id) == ["op-open", "unknown"]
      assert Enum.map(records, & &1.operation_type) == ["open_group", "future_operation"]
      assert Enum.map(records, & &1.submission) == [first, second]
      assert Enum.map(records, & &1.result["status"]) == ["applied", "rejected"]
    end

    test "rolls back domain changes and stops the batch on an unexpected database error" do
      Ecto.Adapters.SQL.query!(Repo, """
      CREATE TRIGGER fail_operation_record
      BEFORE INSERT ON operation_records
      BEGIN
        SELECT RAISE(ABORT, 'forced operation record failure');
      END
      """)

      assert_raise Exqlite.Error, fn ->
        GroupStay.Operations.submit_batch([
          open_operation(),
          open_operation(%{"operation_id" => "later", "group_id" => "later"})
        ])
      end

      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_operation_record")

      assert GroupStay.Operations.get_group("group-1") == nil
      assert GroupStay.Operations.get_group("later") == nil
      assert GroupStay.Operations.get_operation("op-open") == nil
    end

    test "allocates funding by room and settles selected rooms in original order", %{conn: conn} do
      assert [_opened, _paid, cancelled] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 10_000, 1),
                 cancel_rooms_operation("cancel-room", ["room-a"], "2026-11-26", 2)
               ])

      assert cancelled == %{
               "operation_id" => "cancel-room",
               "status" => "applied",
               "group_id" => "group-1",
               "cancelled_room_ids" => ["room-a"],
               "refunded_cents" => 9000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "status" => "active",
               "lodging_total_cents" => 52_500,
               "deposit_due_cents" => 10_500,
               "deposit_paid_cents" => 1000,
               "outstanding_deposit_cents" => 9500,
               "rooms" => [
                 %{
                   "room_id" => "room-a",
                   "status" => "cancelled",
                   "deposit_due_cents" => 9000,
                   "cash_paid_cents" => 0
                 },
                 %{
                   "room_id" => "room-b",
                   "status" => "active",
                   "deposit_due_cents" => 10_500,
                   "cash_paid_cents" => 1000
                 }
               ]
             } = group_data("group-1")

      assert [invalid] =
               submit(build_conn(), [
                 cancel_rooms_operation(
                   "invalid-room-selection",
                   ["room-b", "room-b"],
                   "2026-11-26",
                   3
                 )
               ])

      assert invalid["code"] == "invalid_rooms"
      assert group_data("group-1")["revision"] == 3
    end

    test "reduces only the target payment in reverse fill order and reconciles it", %{conn: conn} do
      assert [_opened, _first, _second, reduced] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay-first", 9500, 1),
                 payment_operation("pay-second", 5000, 2),
                 reduce_operation("reduce", "pay-first", 1000, 3)
               ])

      assert reduced == %{
               "operation_id" => "reduce",
               "status" => "applied",
               "payment_operation_id" => "pay-first",
               "group_id" => "group-1",
               "amount_cents" => 1000,
               "outstanding_deposit_cents" => 6000,
               "revision" => 4
             }

      assert [%{"cash_paid_cents" => 8500}, %{"cash_paid_cents" => 5000}] =
               group_data("group-1")["rooms"]

      assert payment_data("pay-first") == %{
               "payment_operation_id" => "pay-first",
               "original_group_id" => "group-1",
               "recorded_cents" => 9500,
               "held_cents" => 8500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             }

      assert [excessive, reducible_second] =
               submit(build_conn(), [
                 reduce_operation("too-large", "pay-first", 9000, 4),
                 reduce_operation("all-second", "pay-second", 5000, 4)
               ])

      assert excessive["code"] == "reduction_exceeds_held_cash"
      assert reducible_second["status"] == "applied"
      assert ledger_data()["cash_reduced_cents"] == 6000

      assert [empty] =
               submit(build_conn(), [reduce_operation("empty", "pay-second", 1, 5)])

      assert empty["code"] == "payment_not_reducible"
    end

    test "charges back held and historically settled payment cash", %{conn: conn} do
      assert [_opened, _paid, held_chargeback] =
               submit(conn, [
                 open_operation(),
                 payment_operation("held-pay", 1000, 1),
                 chargeback_operation("held-chargeback", "held-pay", 2)
               ])

      assert held_chargeback["charged_back_cents"] == 1000
      assert held_chargeback["outstanding_deposit_cents"] == 19_500

      assert [_opened, _paid, _cancelled, refund_chargeback] =
               submit(build_conn(), [
                 open_operation(%{"operation_id" => "open-2", "group_id" => "group-2"}),
                 payment_operation("refund-pay", 2000, 1) |> Map.put("group_id", "group-2"),
                 cancel_operation("refund-cancel", "2026-11-26", 2)
                 |> Map.put("group_id", "group-2"),
                 chargeback_operation("refund-chargeback", "refund-pay", 3)
               ])

      assert refund_chargeback["group_id"] == "group-2"
      assert refund_chargeback["charged_back_cents"] == 2000
      assert refund_chargeback["outstanding_deposit_cents"] == 0

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_charged_back_cents" => 3000
             } = ledger_data()
    end

    test "chargeback revokes converted entitlement and restoration absorbs shortfall", %{
      conn: conn
    } do
      submit(conn, [
        open_operation(),
        payment_operation("source-pay", 1000, 1),
        cancel_operation("source-credit", "2026-11-26", 2, "hotel_credit")
      ])

      assert [_opened, _applied] =
               submit(build_conn(), [
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "occurred_on" => "2026-12-01"
                 }),
                 credit_operation("use-credit", "destination", 1100, "2026-12-02", 1)
               ])

      assert [charged_back] =
               submit(build_conn(), [
                 chargeback_operation("chargeback", "source-pay", 3)
               ])

      assert charged_back["charged_back_cents"] == 1000
      assert group_data("destination")["revision"] == 2
      assert ledger_data("2026-12-03")["credit_liability_cents"] == 1100
      assert ledger_data("2026-12-03")["credit_shortfall_cents"] == 1100

      assert [%{"status" => "applied"}] =
               submit(build_conn(), [
                 cancel_operation("restore", "2026-11-26", 2)
                 |> Map.put("group_id", "destination")
               ])

      assert guest_credit_data("guest-1", "2026-12-03")["available_cents"] == 0
      assert ledger_data("2026-12-03")["credit_liability_cents"] == 0
      assert ledger_data("2026-12-03")["credit_shortfall_cents"] == 0
    end

    test "cancels the final rooms in original order and applies one combined credit bonus", %{
      conn: conn
    } do
      assert [_opened, _paid, cancelled] =
               submit(conn, [
                 open_operation(%{
                   "rooms" => [
                     %{"room_id" => "room-a", "nightly_rate_cents" => 8},
                     %{"room_id" => "room-b", "nightly_rate_cents" => 17}
                   ]
                 }),
                 payment_operation("pay", 5, 1),
                 cancel_rooms_operation(
                   "cancel-both",
                   ["room-b", "room-a"],
                   "2026-11-26",
                   2
                 )
                 |> Map.put("refund_method", "hotel_credit")
               ])

      assert cancelled["cancelled_room_ids"] == ["room-a", "room-b"]
      assert cancelled["credit_issued_cents"] == 6
      assert group_data("group-1")["status"] == "cancelled"
      assert group_data("group-1")["deposit_due_cents"] == 0
      assert guest_credit_data("guest-1", "2026-11-26")["available_cents"] == 6
    end

    test "validates correction targets, dates, and stale revisions before reducibility", %{
      conn: conn
    } do
      assert [_opened, _paid] =
               submit(conn, [open_operation(), payment_operation("pay", 1000, 1)])

      missing_date = reduce_operation("missing-date", "pay", 1, 2) |> Map.delete("occurred_on")

      invalid_date =
        chargeback_operation("invalid-date", "pay", 2) |> Map.put("occurred_on", "bad")

      assert [
               missing_target,
               wrong_reduce,
               wrong_chargeback,
               stale,
               bad_date,
               bad_chargeback_date
             ] =
               submit(build_conn(), [
                 reduce_operation("missing-target", "absent", 1, 2),
                 reduce_operation("wrong-reduce", "op-open", 1, 2),
                 chargeback_operation("wrong-chargeback", "op-open", 2),
                 reduce_operation("stale-reduce", "pay", -1, 1),
                 missing_date,
                 invalid_date
               ])

      assert missing_target["code"] == "operation_not_found"
      assert wrong_reduce["code"] == "payment_not_reducible"
      assert wrong_chargeback["code"] == "payment_not_chargeable"
      assert stale["code"] == "stale_revision"
      assert bad_date["code"] == "invalid_operation"
      assert bad_chargeback_date["code"] == "invalid_operation"
      assert group_data("group-1")["revision"] == 2
    end

    test "keeps correction operations durable without rewriting the payment result", %{conn: conn} do
      payment = payment_operation("pay", 1000, 1)
      reduction = reduce_operation("reduce", "pay", 500, 2)

      assert [_opened, original_payment] = submit(conn, [open_operation(), payment])

      assert [original_reduction, replayed_reduction] =
               submit(build_conn(), [reduction, reduction])

      assert replayed_reduction == original_reduction
      assert [replayed_payment] = submit(build_conn(), [payment])
      assert replayed_payment == original_payment
      assert payment_data("pay")["held_cents"] == 500

      assert [%{"code" => "operation_id_conflict"}] =
               submit(build_conn(), [Map.put(reduction, "amount_cents", 1)])
    end

    test "backfills legacy cash ahead of durable funding without changing balances", %{conn: conn} do
      submit(conn, [
        open_operation(),
        payment_operation("legacy-pay", 2000, 1),
        payment_operation("durable-pay", 1000, 2)
      ])

      group = Repo.get_by!(GroupStay.Group, group_id: "group-1")

      Repo.delete_all(
        from allocation in GroupStay.RoomFundingAllocation,
          where: allocation.group_record_id == ^group.id
      )

      Repo.delete_all(
        from payment in GroupStay.CashPayment, where: payment.group_record_id == ^group.id
      )

      Repo.delete!(Repo.get_by!(OperationRecord, operation_id: "legacy-pay"))

      Repo.update_all(from(item in GroupStay.Group, where: item.id == ^group.id),
        set: [accounting_initialized: false]
      )

      GroupStay.Group |> Repo.get!(group.id) |> GroupStay.Accounting.ensure_group()

      assert Repo.all(
               from allocation in GroupStay.RoomFundingAllocation,
                 where: allocation.group_record_id == ^group.id,
                 order_by: allocation.allocation_order,
                 select: {allocation.source_operation_id, allocation.amount_cents}
             ) == [{nil, 2000}, {"durable-pay", 1000}]

      assert group_data("group-1")["cash_paid_cents"] == 3000
      assert ledger_data()["cash_held_cents"] == 3000
      assert payment_data("durable-pay")["held_cents"] == 1000
    end

    test "telescopes converted-credit entitlements in payment funding order", %{conn: conn} do
      assert [_opened, _first, _second, %{"credit_issued_cents" => 11}] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay-first", 5, 1),
                 payment_operation("pay-second", 5, 2),
                 cancel_operation("convert", "2026-11-26", 3, "hotel_credit")
               ])

      assert [%{"charged_back_cents" => 5}] =
               submit(build_conn(), [
                 chargeback_operation("chargeback-second", "pay-second", 4)
               ])

      assert guest_credit_data("guest-1", "2026-11-26")["available_cents"] == 6

      assert [%{"charged_back_cents" => 5}] =
               submit(build_conn(), [
                 chargeback_operation("chargeback-first", "pay-first", 5)
               ])

      assert guest_credit_data("guest-1", "2026-11-26")["available_cents"] == 0
      assert ledger_data("2026-11-26")["cash_converted_to_credit_cents"] == 0
      assert ledger_data("2026-11-26")["cash_charged_back_cents"] == 10
    end

    test "transfers mixed funding in reverse allocation order and replays durably", %{conn: conn} do
      assert [_opened, _paid, %{"credit_issued_cents" => 1100}] =
               submit(conn, [
                 open_operation(%{
                   "operation_id" => "open-credit-origin",
                   "group_id" => "credit-origin"
                 }),
                 payment_operation("credit-origin-pay", 1000, 1)
                 |> Map.put("group_id", "credit-origin"),
                 cancel_operation("credit-origin-cancel", "2026-11-26", 2, "hotel_credit")
                 |> Map.put("group_id", "credit-origin")
               ])

      operations = [
        open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
        payment_operation("source-pay", 2000, 1) |> Map.put("group_id", "source"),
        credit_operation("source-credit", "source", 1000, "2026-11-27", 2),
        open_operation(%{
          "operation_id" => "open-destination",
          "group_id" => "destination",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "small", "nightly_rate_cents" => 1000},
            %{"room_id" => "large", "nightly_rate_cents" => 10_000}
          ]
        }),
        transfer_operation("transfer", "source", "destination", 1500, 3, 1)
      ]

      assert [_source, _cash, _credit, _destination, transfer] = submit(build_conn(), operations)

      assert transfer == %{
               "operation_id" => "transfer",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 1500,
               "source_outstanding_deposit_cents" => 18_000,
               "destination_outstanding_deposit_cents" => 700,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      assert group_data("destination")["rooms"]
             |> Enum.map(&Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])) == [
               %{"room_id" => "small", "cash_paid_cents" => 0, "credit_paid_cents" => 200},
               %{
                 "room_id" => "large",
                 "cash_paid_cents" => 500,
                 "credit_paid_cents" => 800
               }
             ]

      assert payment_data("source-pay")["held_by_group"] == [
               %{"group_id" => "destination", "amount_cents" => 500},
               %{"group_id" => "source", "amount_cents" => 1500}
             ]

      refute Map.has_key?(payment_data("credit-origin-pay"), "held_by_group")

      ledger_before_replay = ledger_data("2026-11-27")
      assert [replayed] = submit(build_conn(), [List.last(operations)])
      assert replayed == transfer
      assert ledger_data("2026-11-27") == ledger_before_replay
      assert group_data("source")["revision"] == 4
      assert group_data("destination")["revision"] == 2

      assert [cancelled] =
               submit(build_conn(), [
                 cancel_operation("cancel-destination", "2026-11-26", 2, "hotel_credit")
                 |> Map.put("group_id", "destination")
               ])

      assert cancelled["credit_issued_cents"] == 550
      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 0
      assert guest_credit_data("guest-1", "2026-11-26")["available_cents"] == 1650

      assert payment_data("source-pay")["held_by_group"] == [
               %{"group_id" => "source", "amount_cents" => 1500}
             ]
    end

    test "resolves both transfer groups and revisions before transfer validation", %{conn: conn} do
      assert [_source, _paid, _destination, _other_guest] =
               submit(conn, [
                 open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
                 payment_operation("pay", 1000, 1) |> Map.put("group_id", "source"),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination"
                 }),
                 open_operation(%{
                   "operation_id" => "open-other",
                   "group_id" => "other",
                   "guest_id" => "guest-2"
                 })
               ])

      malformed_destination =
        transfer_operation("missing-source-malformed-destination", "absent", "unused", -1)
        |> Map.delete("destination_group_id")

      assert [
               missing_source,
               missing_source_malformed_destination,
               missing_destination,
               stale_source,
               stale_destination,
               invalid_guest
             ] =
               submit(build_conn(), [
                 transfer_operation("missing-source", "missing", "also-missing", -1),
                 malformed_destination,
                 transfer_operation("missing-destination", "source", "missing", -1),
                 transfer_operation("stale-source", "source", "destination", -1, 1, 1),
                 transfer_operation("stale-destination", "source", "destination", -1, 2, 0),
                 transfer_operation("other-guest", "source", "other", 1, 2, 1)
               ])

      assert %{"code" => "group_not_found", "group_id" => "missing"} = missing_source

      assert %{"code" => "group_not_found", "group_id" => "absent"} =
               missing_source_malformed_destination

      assert %{"code" => "group_not_found", "group_id" => "missing"} = missing_destination

      assert %{"code" => "stale_revision", "group_id" => "source", "actual_revision" => 2} =
               stale_source

      assert %{
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 0,
               "actual_revision" => 1
             } = stale_destination

      assert invalid_guest["code"] == "invalid_transfer"
      assert group_data("source")["revision"] == 2
      assert group_data("destination")["revision"] == 1
      assert payment_data("pay")["held_cents"] == 1000
    end

    test "returns transfer domain errors without changing either group", %{conn: conn} do
      assert [_source, _paid, _destination, _full_payment] =
               submit(conn, [
                 open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
                 payment_operation("pay", 1000, 1) |> Map.put("group_id", "source"),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "rooms" => [%{"room_id" => "only", "nightly_rate_cents" => 5000}],
                   "arrival_on" => "2026-12-10",
                   "departure_on" => "2026-12-11"
                 }),
                 payment_operation("destination-pay", 1000, 1)
                 |> Map.put("group_id", "destination")
               ])

      assert [same, invalid_amount, excessive_source, excessive_destination] =
               submit(build_conn(), [
                 transfer_operation("same", "source", "source", 1, 2, 2),
                 transfer_operation("invalid-amount", "source", "destination", 0, 2, 2),
                 transfer_operation("excessive-source", "source", "destination", 1001, 2, 2),
                 transfer_operation("excessive-destination", "source", "destination", 1, 2, 2)
               ])

      assert same["code"] == "invalid_transfer"
      assert invalid_amount["code"] == "invalid_amount"
      assert excessive_source["code"] == "transfer_exceeds_held_funding"
      assert excessive_destination["code"] == "transfer_exceeds_outstanding"
      assert group_data("source")["revision"] == 2
      assert group_data("destination")["revision"] == 2
      assert ledger_data()["cash_held_cents"] == 2000

      assert [_cancelled, inactive_destination] =
               submit(build_conn(), [
                 cancel_operation("cancel-destination", "2026-11-26", 2)
                 |> Map.put("group_id", "destination"),
                 transfer_operation("inactive-destination", "source", "destination", 1, 2, 3)
               ])

      assert %{"code" => "group_not_active", "group_id" => "destination"} =
               inactive_destination
    end

    test "settles transferred cash under the destination policy and charges it back across groups",
         %{
           conn: conn
         } do
      assert [_source, _paid, _destination, transferred, settled] =
               submit(conn, [
                 open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
                 payment_operation("pay", 1000, 1) |> Map.put("group_id", "source"),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "rate_plan" => "advance_purchase"
                 }),
                 transfer_operation("transfer", "source", "destination", 1000, 2, 1),
                 cancel_operation("settle-destination", "2026-11-26", 2)
                 |> Map.put("group_id", "destination")
               ])

      assert transferred["source_revision"] == 3
      assert transferred["destination_revision"] == 2
      assert settled["retained_cents"] == 1000
      assert payment_data("pay")["held_by_group"] == []

      assert [chargeback] =
               submit(build_conn(), [chargeback_operation("chargeback", "pay", 3)])

      assert chargeback["revision"] == 4
      assert chargeback["charged_back_cents"] == 1000
      assert group_data("source")["revision"] == 4
      assert group_data("destination")["revision"] == 4
      assert ledger_data()["cash_retained_cents"] == 0
      assert ledger_data()["cash_charged_back_cents"] == 1000
    end

    test "reduces transferred payment allocations newest-first across all groups", %{conn: conn} do
      assert [_source, _paid, _first, _second, _first_transfer, _second_transfer, reduced] =
               submit(conn, [
                 open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
                 payment_operation("pay", 3000, 1) |> Map.put("group_id", "source"),
                 open_operation(%{"operation_id" => "open-a", "group_id" => "a"}),
                 open_operation(%{"operation_id" => "open-b", "group_id" => "b"}),
                 transfer_operation("transfer-a", "source", "a", 1000, 2, 1),
                 transfer_operation("transfer-b", "source", "b", 500, 3, 1),
                 reduce_operation("reduce", "pay", 1200, 4)
               ])

      assert reduced["revision"] == 5
      assert group_data("source")["revision"] == 5
      assert group_data("a")["revision"] == 3
      assert group_data("b")["revision"] == 3
      assert group_data("source")["cash_paid_cents"] == 1500
      assert group_data("a")["cash_paid_cents"] == 300
      assert group_data("b")["cash_paid_cents"] == 0

      assert payment_data("pay")["held_by_group"] == [
               %{"group_id" => "a", "amount_cents" => 300},
               %{"group_id" => "source", "amount_cents" => 1500}
             ]
    end

    test "starts reporting from the state immediately before the operation", %{conn: conn} do
      start = start_reporting_operation("start", "2026-10-10")

      assert [_opened, _opening_payment, started, movement, movement_replayed, replayed] =
               submit(conn, [
                 open_operation(),
                 payment_operation("opening-payment", 1000, 1),
                 start,
                 payment_operation("movement", 500, 2),
                 payment_operation("movement", 500, 2),
                 start
               ])

      assert started == %{
               "operation_id" => "start",
               "status" => "applied",
               "starts_on" => "2026-10-10"
             }

      assert replayed == started
      assert movement_replayed == movement
      assert movement["revision"] == 3

      assert %{
               "date" => "2026-10-10",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 1000,
                   "movements" => %{
                     "received_cents" => 500,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 1500
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
               }
             } = finance_report_data("2026-10-10")

      assert [%{"code" => "reporting_already_started"}] =
               submit(build_conn(), [start_reporting_operation("another-start", "2026-10-10")])

      assert finance_report_data("2026-10-10")["cash"]
             |> List.first()
             |> Map.fetch!("closing_held_cents") == 1500
    end

    test "reports transfers and later reductions at the property holding the cash", %{conn: conn} do
      assert [_source, _paid, _destination, _started, _transferred, _reduced] =
               submit(conn, [
                 open_operation(%{"operation_id" => "open-source", "group_id" => "source"}),
                 payment_operation("pay", 1000, 1) |> Map.put("group_id", "source"),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "property_id" => "berlin-mitte"
                 }),
                 start_reporting_operation("start", "2026-10-10"),
                 transfer_operation("transfer", "source", "destination", 1000, 2, 1),
                 reduce_operation("reduce", "pay", 500, 3)
               ])

      assert [source, destination] = finance_report_data("2026-10-10")["cash"]

      assert source == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 1000,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 0
             }

      assert destination["property_id"] == "berlin-mitte"
      assert destination["opening_held_cents"] == 0
      assert destination["movements"]["transferred_in_cents"] == 1000
      assert destination["movements"]["reduced_cents"] == 500
      assert destination["closing_held_cents"] == 500
    end

    test "reports signed settlement reversals when a payment is charged back", %{conn: conn} do
      assert [_opened, _paid, _started, _cancelled, _charged_back] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 1000, 1),
                 start_reporting_operation("start", "2026-11-26"),
                 cancel_operation("refund", "2026-11-26", 2),
                 chargeback_operation("chargeback", "pay", 3)
                 |> Map.put("occurred_on", "2026-11-27")
               ])

      day_one = finance_report_data("2026-11-26")["cash"] |> List.first()
      assert day_one["opening_held_cents"] == 1000
      assert day_one["movements"]["refunded_cents"] == 1000
      assert day_one["closing_held_cents"] == 0

      day_two = finance_report_data("2026-11-27")["cash"] |> List.first()
      assert day_two["opening_held_cents"] == 0
      assert day_two["movements"]["refunded_cents"] == -1000
      assert day_two["movements"]["charged_back_cents"] == 1000
      assert day_two["closing_held_cents"] == 0
    end

    test "reports issued credit and passive expiry without changing domain state", %{conn: conn} do
      assert [_opened, _paid, _started, %{"credit_issued_cents" => 1100}] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 1000, 1),
                 start_reporting_operation("start", "2026-11-26"),
                 cancel_operation("issue", "2026-11-26", 2, "hotel_credit")
               ])

      issued = finance_report_data("2026-11-26")
      assert issued["credit"]["movements"]["issued_cents"] == 1100
      assert issued["credit"]["closing_liability_cents"] == 1100

      assert issued["cash"] |> List.first() |> get_in(["movements", "converted_to_credit_cents"]) ==
               1000

      before_expiry = finance_report_data("2027-11-26")
      assert before_expiry["credit"]["closing_liability_cents"] == 1100

      expired = finance_report_data("2027-11-27")
      assert expired["credit"]["opening_liability_cents"] == 1100
      assert expired["credit"]["movements"]["expired_cents"] == 1100
      assert expired["credit"]["closing_liability_cents"] == 0

      assert finance_report_data("2027-11-27") == expired
      assert guest_credit_data("guest-1", "2027-11-27")["available_cents"] == 0
    end

    test "recomputes opening-day expiry when a backdated application is submitted", %{conn: conn} do
      assert [_opened, _paid, _issued, _destination, _started, _applied] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 1000, 1),
                 cancel_operation("issue", "2026-11-26", 2, "hotel_credit"),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "occurred_on" => "2027-01-01",
                   "arrival_on" => "2028-02-01",
                   "departure_on" => "2028-02-04"
                 }),
                 start_reporting_operation("start", "2027-11-27"),
                 credit_operation("apply", "destination", 1100, "2027-11-26", 1)
               ])

      report = finance_report_data("2027-11-27")
      assert report["credit"]["opening_liability_cents"] == 1100
      assert report["credit"]["movements"]["expired_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 1100
      assert ledger_data("2027-11-27")["credit_liability_cents"] == 1100
    end

    test "reports credit consumption by non-refundable settlement", %{conn: conn} do
      assert [_source, _paid, _destination, _started, _issued, _applied, _consumed] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 1000, 1),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination",
                   "rate_plan" => "advance_purchase"
                 }),
                 start_reporting_operation("start", "2026-11-26"),
                 cancel_operation("issue", "2026-11-26", 2, "hotel_credit"),
                 credit_operation("apply", "destination", 1100, "2026-11-26", 1),
                 cancel_operation("consume", "2026-11-26", 2)
                 |> Map.put("group_id", "destination")
               ])

      credit = finance_report_data("2026-11-26")["credit"]
      assert credit["movements"]["issued_cents"] == 1100
      assert credit["movements"]["consumed_cents"] == 1100
      assert credit["closing_liability_cents"] == 0
      assert ledger_data("2026-11-26")["credit_liability_cents"] == 0
    end

    test "reports shortfall absorption when charged-back credit is restored", %{conn: conn} do
      assert [_source, _paid, _destination, _started, _issued, _applied, _chargeback, _absorbed] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 1000, 1),
                 open_operation(%{
                   "operation_id" => "open-destination",
                   "group_id" => "destination"
                 }),
                 start_reporting_operation("start", "2026-11-26"),
                 cancel_operation("issue", "2026-11-26", 2, "hotel_credit"),
                 credit_operation("apply", "destination", 1100, "2026-11-26", 1),
                 chargeback_operation("chargeback", "pay", 3)
                 |> Map.put("occurred_on", "2026-11-26"),
                 cancel_operation("absorb", "2026-11-26", 2)
                 |> Map.put("group_id", "destination")
               ])

      credit = finance_report_data("2026-11-26")["credit"]
      assert credit["movements"]["issued_cents"] == 1100
      assert credit["movements"]["revoked_cents"] == 0
      assert credit["movements"]["absorbed_cents"] == 1100
      assert credit["closing_liability_cents"] == 0
      assert ledger_data("2026-11-26")["credit_liability_cents"] == 0
    end

    test "reports revocation of unused credit entitlement", %{conn: conn} do
      assert [_opened, _paid, _started, _issued, _chargeback] =
               submit(conn, [
                 open_operation(),
                 payment_operation("pay", 1000, 1),
                 start_reporting_operation("start", "2026-11-26"),
                 cancel_operation("issue", "2026-11-26", 2, "hotel_credit"),
                 chargeback_operation("chargeback", "pay", 3)
                 |> Map.put("occurred_on", "2026-11-26")
               ])

      credit = finance_report_data("2026-11-26")["credit"]
      assert credit["movements"]["issued_cents"] == 1100
      assert credit["movements"]["revoked_cents"] == 1100
      assert credit["closing_liability_cents"] == 0
      assert ledger_data("2026-11-26")["credit_liability_cents"] == 0
    end
  end

  describe "read endpoints" do
    test "returns an empty ledger", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             }
    end

    test "returns the documented missing-group response", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/groups/missing"), 404) == %{
               "error" => %{"code" => "group_not_found"}
             }
    end

    test "returns the documented missing-operation response", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/operations/missing"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }
    end

    test "returns payment read errors", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/payments/missing"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      submit(build_conn(), [open_operation()])

      assert json_response(get(build_conn(), "/api/v1/payments/op-open"), 422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    test "returns empty guest credit and rejects invalid report dates", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/guests/unknown/credit?on=2027-01-01"), 200) == %{
               "data" => %{"guest_id" => "unknown", "available_cents" => 0, "lots" => []}
             }

      for path <- ["/api/v1/ledger?on=nope", "/api/v1/guests/guest-1/credit?on=nope"] do
        assert json_response(get(build_conn(), path), 422) == %{
                 "error" => %{"code" => "invalid_date"}
               }
      end
    end

    test "validates finance report dates and availability", %{conn: conn} do
      for path <- ["/api/v1/finance/daily-report", "/api/v1/finance/daily-report?date=nope"] do
        assert json_response(get(conn, path), 422) == %{
                 "error" => %{"code" => "invalid_reporting_date"}
               }
      end

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-10"), 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      assert [invalid, missing, started] =
               submit(conn, [
                 start_reporting_operation("invalid", "not-a-date"),
                 start_reporting_operation("missing", "2026-10-10") |> Map.delete("starts_on"),
                 start_reporting_operation("start", "2026-10-10")
               ])

      assert invalid["code"] == "invalid_reporting_date"
      assert missing["code"] == "invalid_reporting_date"
      assert started["status"] == "applied"

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-10-09"), 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group_data(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger_data(on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"

    build_conn()
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit_data(guest_id, on) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp payment_data(payment_operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp finance_report_data(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, amount, expected_revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-1",
      "amount_cents" => amount
    }
    |> maybe_expected_revision(expected_revision)
  end

  defp reschedule_operation(
         operation_id,
         arrival,
         expected_revision,
         occurred_on \\ "2026-10-05"
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "reschedule_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-1",
      "new_arrival_on" => arrival,
      "expected_revision" => expected_revision
    }
  end

  defp credit_operation(operation_id, group_id, amount, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp cancel_operation(operation_id, occurred_on, expected_revision, refund_method \\ nil) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-1",
      "expected_revision" => expected_revision
    }

    if refund_method, do: Map.put(operation, "refund_method", refund_method), else: operation
  end

  defp cancel_rooms_operation(operation_id, room_ids, occurred_on, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => occurred_on,
      "group_id" => "group-1",
      "room_ids" => room_ids,
      "expected_revision" => expected_revision
    }
  end

  defp reduce_operation(operation_id, payment_operation_id, amount, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount,
      "expected_revision" => expected_revision
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id, expected_revision) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2026-10-05",
      "payment_operation_id" => payment_operation_id,
      "expected_revision" => expected_revision
    }
  end

  defp transfer_operation(
         operation_id,
         source_group_id,
         destination_group_id,
         amount,
         expected_revision \\ nil,
         destination_expected_revision \\ nil
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-05",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount
    }
    |> maybe_expected_revision(expected_revision)
    |> then(fn operation ->
      if destination_expected_revision,
        do: Map.put(operation, "destination_expected_revision", destination_expected_revision),
        else: operation
    end)
  end

  defp start_reporting_operation(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp maybe_expected_revision(operation, nil), do: operation

  defp maybe_expected_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)
end
