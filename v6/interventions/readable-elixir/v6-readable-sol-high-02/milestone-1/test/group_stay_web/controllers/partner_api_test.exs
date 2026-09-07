defmodule GroupStayWeb.PartnerApiTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  describe "POST /api/v1/partner-batches" do
    test "rejects an invalid batch", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", %{"not_operations" => []})

      assert response(conn, 422) == ~s({"error":{"code":"invalid_batch"}})

      conn = post(build_conn(), "/api/v1/partner-batches", %{"operations" => %{}})

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_batch"}}
    end

    test "opens a flexible group and exposes its ordered rooms and totals", %{conn: conn} do
      operation = open_operation()

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "open-1",
                   "status" => "applied",
                   "group_id" => "group-1",
                   "deposit_due_cents" => 19_500,
                   "revision" => 1
                 }
               ]
             }

      conn = get(build_conn(), "/api/v1/groups/group-1")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "group_id" => "group-1",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 1,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
                 ],
                 "lodging_total_cents" => 97_500,
                 "deposit_due_cents" => 19_500,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 19_500
               }
             }
    end

    test "rounds each flexible room separately and charges advance purchase in full", %{
      conn: conn
    } do
      flexible =
        open_operation(%{
          "operation_id" => "open-flex",
          "group_id" => "tiny-flex",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [
            %{"room_id" => "a", "nightly_rate_cents" => 2},
            %{"room_id" => "b", "nightly_rate_cents" => 3}
          ]
        })

      advance =
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase"
        })

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => [flexible, advance]})

      assert %{
               "results" => [
                 %{"deposit_due_cents" => 1, "status" => "applied"},
                 %{"deposit_due_cents" => 97_500, "status" => "applied"}
               ]
             } = json_response(conn, 200)
    end

    test "rejects invalid open operations without creating groups", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "no-nights",
          "group_id" => "invalid-stay",
          "departure_on" => "2026-12-10"
        }),
        open_operation(%{
          "operation_id" => "bad-date",
          "group_id" => "invalid-date",
          "arrival_on" => "not-a-date"
        }),
        open_operation(%{
          "operation_id" => "no-rooms",
          "group_id" => "invalid-rooms",
          "rooms" => []
        }),
        open_operation(%{
          "operation_id" => "duplicate-room",
          "group_id" => "duplicate-room-group",
          "rooms" => [
            %{"room_id" => "same", "nightly_rate_cents" => 100},
            %{"room_id" => "same", "nightly_rate_cents" => 200}
          ]
        }),
        open_operation(%{
          "operation_id" => "bad-rate",
          "group_id" => "invalid-rate",
          "rate_plan" => "weekly"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, &{&1["operation_id"], &1["code"]}) == [
               {"no-nights", "invalid_stay"},
               {"bad-date", "invalid_stay"},
               {"no-rooms", "invalid_rooms"},
               {"duplicate-room", "invalid_rooms"},
               {"bad-rate", "invalid_rate_plan"}
             ]

      assert Repo.aggregate(Group, :count) == 0
    end

    test "keeps processing after failures and lets later operations see earlier changes", %{
      conn: conn
    } do
      operations = [
        %{"operation_id" => "unknown", "type" => "unknown", "occurred_on" => "2026-10-03"},
        open_operation(),
        open_operation(%{"operation_id" => "duplicate"}),
        payment_operation(%{"operation_id" => "pay-1", "amount_cents" => 5_000}),
        payment_operation(%{"operation_id" => "too-much", "amount_cents" => 20_000}),
        payment_operation(%{"operation_id" => "pay-2", "amount_cents" => 2_000})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})

      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(results, & &1["status"]) ==
               ~w(rejected applied rejected applied rejected applied)

      assert Enum.at(results, 0)["code"] == "invalid_operation"
      assert Enum.at(results, 2)["code"] == "group_already_exists"
      assert Enum.at(results, 4)["code"] == "payment_exceeds_outstanding"

      assert Enum.at(results, 3) == %{
               "operation_id" => "pay-1",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "revision" => 2
             }

      assert Enum.at(results, 5)["revision"] == 3
      assert Repo.get!(Group, "group-1").deposit_paid_cents == 7_000
    end

    test "validates payment amounts", %{conn: conn} do
      operations = [
        open_operation(),
        payment_operation(%{"operation_id" => "zero", "amount_cents" => 0}),
        payment_operation(%{"operation_id" => "fraction", "amount_cents" => 10.5}),
        payment_operation(%{"operation_id" => "bad-date", "occurred_on" => "not-a-date"}),
        payment_operation(%{"operation_id" => "missing-group", "group_id" => "absent"}),
        Map.delete(payment_operation(%{"operation_id" => "missing-amount"}), "amount_cents")
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.map(Enum.drop(results, 1), & &1["code"]) == [
               "invalid_amount",
               "invalid_amount",
               "invalid_operation",
               "group_not_found",
               "invalid_operation"
             ]

      group = Repo.get!(Group, "group-1")
      assert group.revision == 1
      assert group.deposit_paid_cents == 0
    end

    test "checks revisions before domain rules and never changes state for stale operations", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation(%{"operation_id" => "pay", "amount_cents" => 1_000}),
        payment_operation(%{
          "operation_id" => "stale",
          "amount_cents" => -10,
          "expected_revision" => 1
        }),
        payment_operation(%{
          "operation_id" => "missing",
          "group_id" => "absent",
          "expected_revision" => 99
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.at(results, 2) == %{
               "operation_id" => "stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-1",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert Enum.at(results, 3)["code"] == "group_not_found"

      group = Repo.get!(Group, "group-1")
      assert group.revision == 2
      assert group.deposit_paid_cents == 1_000

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 1_000,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }
    end

    test "reschedules an active group without changing its stay length or price", %{conn: conn} do
      operations = [
        open_operation(),
        reschedule_operation(%{"expected_revision" => 1}),
        reschedule_operation(%{
          "operation_id" => "invalid-move",
          "occurred_on" => "2027-01-01",
          "new_arrival_on" => "2027-01-01"
        })
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.at(results, 1) == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "group-1",
               "new_arrival_on" => "2027-01-10",
               "new_departure_on" => "2027-01-13",
               "revision" => 2
             }

      assert Enum.at(results, 2)["code"] == "invalid_stay"

      group = Repo.get!(Group, "group-1")
      assert group.revision == 2
      assert group.lodging_total_cents == 97_500
      assert group.deposit_due_cents == 19_500
      assert group.arrival_on == ~D[2027-01-10]
      assert group.departure_on == ~D[2027-01-13]
    end

    test "refunds a flexible group at the 14-day boundary and rejects later changes", %{
      conn: conn
    } do
      operations = [
        open_operation(),
        payment_operation(%{"amount_cents" => 8_000}),
        cancel_operation(%{"occurred_on" => "2026-11-26", "expected_revision" => 2}),
        payment_operation(%{"operation_id" => "after-pay", "amount_cents" => 1}),
        reschedule_operation(%{"operation_id" => "after-move", "expected_revision" => 3}),
        cancel_operation(%{"operation_id" => "again", "expected_revision" => 3})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.at(results, 2) == %{
               "operation_id" => "cancel-1",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 8_000,
               "retained_cents" => 0,
               "revision" => 3
             }

      assert Enum.map(Enum.drop(results, 3), & &1["code"]) ==
               ~w(group_not_active group_not_active group_not_active)

      conn = get(build_conn(), "/api/v1/groups/group-1")
      assert %{"data" => group} = json_response(conn, 200)
      assert group["status"] == "cancelled"
      assert group["deposit_paid_cents"] == 8_000
      assert group["outstanding_deposit_cents"] == 0
      assert group["revision"] == 3

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 8_000,
               "cash_retained_cents" => 0
             }
    end

    test "retains late flexible and all advance-purchase cash in aggregate ledger totals", %{
      conn: conn
    } do
      late_flexible = open_operation(%{"group_id" => "late", "operation_id" => "open-late"})

      advance =
        open_operation(%{
          "group_id" => "advance",
          "operation_id" => "open-advance",
          "rate_plan" => "advance_purchase"
        })

      held = open_operation(%{"group_id" => "held", "operation_id" => "open-held"})

      operations = [
        late_flexible,
        payment_operation(%{"group_id" => "late", "amount_cents" => 2_000}),
        cancel_operation(%{"group_id" => "late", "occurred_on" => "2026-11-27"}),
        advance,
        payment_operation(%{"group_id" => "advance", "amount_cents" => 3_000}),
        cancel_operation(%{"group_id" => "advance", "occurred_on" => "2026-10-04"}),
        held,
        payment_operation(%{"group_id" => "held", "amount_cents" => 4_000})
      ]

      conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn = get(build_conn(), "/api/v1/ledger")

      assert json_response(conn, 200)["data"] == %{
               "cash_held_cents" => 4_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 5_000
             }
    end
  end

  describe "GET read endpoints" do
    test "reports an empty ledger and a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             }

      conn = get(build_conn(), "/api/v1/groups/absent")
      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-1",
        "guest_id" => "guest-22",
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

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1",
        "new_arrival_on" => "2027-01-10"
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-1"
      },
      overrides
    )
  end
end
