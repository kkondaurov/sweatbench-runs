defmodule GroupStayWeb.ApiControllerTest do
  use GroupStayWeb.ConnCase

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
                   %{"room_id" => "room-a", "nightly_rate_cents" => 3},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 3}
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
               "deposit_due_cents" => 19_500,
               "deposit_paid_cents" => 5000,
               "outstanding_deposit_cents" => 0
             } = group_data("group-1")

      assert ledger_data() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
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
               "credit_liability_cents" => 0
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
  end

  describe "read endpoints" do
    test "returns an empty ledger", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "returns the documented missing-group response", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/groups/missing"), 404) == %{
               "error" => %{"code" => "group_not_found"}
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

  defp maybe_expected_revision(operation, nil), do: operation

  defp maybe_expected_revision(operation, revision),
    do: Map.put(operation, "expected_revision", revision)
end
