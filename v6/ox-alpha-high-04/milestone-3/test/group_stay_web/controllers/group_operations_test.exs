defmodule GroupStayWeb.GroupOperationsTest do
  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  describe "record_cash_payment" do
    test "applies cash to the outstanding deposit", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn = post(conn, "/api/v1/partner-batches", batch([pay("group-81", 10000)]))

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 10000,
                 "outstanding_deposit_cents" => 9500,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "partial payments accumulate until the deposit is settled", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 10000)]))

      conn =
        post(
          conn,
          "/api/v1/partner-batches",
          batch([pay("group-81", 9500, %{"operation_id" => "op-pay-final"})])
        )

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 3}] =
               json_response(conn, 200)["results"]
    end

    test "rejects payments that exceed the outstanding deposit", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn = post(conn, "/api/v1/partner-batches", batch([pay("group-81", 19501)]))

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               json_response(conn, 200)["results"]
    end

    test "rejects amounts that are not usable as payments", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      for {bad, index} <- Enum.with_index([0, -5000, 12.5, "10000"]) do
        conn =
          post(
            conn,
            "/api/v1/partner-batches",
            batch([pay("group-81", bad, %{"operation_id" => "op-bad-#{index}"})])
          )

        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 json_response(conn, 200)["results"]
      end
    end

    test "rejects missing, inactive, and cancelled groups", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", batch([pay("ghost", 100)]))

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               json_response(conn, 200)["results"]

      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-12-01")]))

      conn = post(conn, "/api/v1/partner-batches", batch([pay("group-81", 100)]))

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               json_response(conn, 200)["results"]
    end

    test "a rejected payment never increments the revision", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 19501)]))

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 1, "deposit_paid_cents" => 0}} = json_response(conn, 200)
    end
  end

  describe "reschedule_group" do
    test "shifts the departure by the same number of days without changing price", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn = post(conn, "/api/v1/partner-batches", batch([reschedule("group-81", "2027-01-05")]))

      # Same 3-night stay, moved 26 days later: 2026-12-13 + 26 days = 2027-01-08.
      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-01-05",
                 "new_departure_on" => "2027-01-08",
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{
               "data" => %{
                 "arrival_on" => "2027-01-05",
                 "departure_on" => "2027-01-08",
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500
               }
             } =
               json_response(conn, 200)
    end

    test "rejects new arrivals that are not after the operation date", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      for {date, index} <- Enum.with_index(["2026-11-01", "2026-10-31", "not-a-date"]) do
        conn =
          post(
            conn,
            "/api/v1/partner-batches",
            batch([reschedule("group-81", date, %{"operation_id" => "op-move-bad-#{index}"})])
          )

        assert [%{"status" => "rejected", "code" => "invalid_stay"}] =
                 json_response(conn, 200)["results"]
      end
    end

    test "rejects missing, inactive, and cancelled groups", %{conn: conn} do
      conn = post(conn, "/api/v1/partner-batches", batch([reschedule("ghost", "2027-01-05")]))

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               json_response(conn, 200)["results"]

      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-12-01")]))

      conn = post(conn, "/api/v1/partner-batches", batch([reschedule("group-81", "2027-01-05")]))

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               json_response(conn, 200)["results"]
    end
  end

  describe "cancel_group" do
    test "refunds a flexible reservation cancelled at least 14 days before arrival", %{conn: conn} do
      # arrival 2026-12-10; cancel on 2026-11-26 is exactly 14 days before.
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 19500)]))

      conn = post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-11-26")]))

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 19500,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"status" => "cancelled", "deposit_paid_cents" => 19500}} =
               json_response(conn, 200)
    end

    test "retains cash for a flexible reservation cancelled less than 14 days before arrival", %{
      conn: conn
    } do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 5000)]))

      conn = post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-11-27")]))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5000}] =
               json_response(conn, 200)["results"]
    end

    test "advance_purchase reservations are always non-refundable", %{conn: conn} do
      post(
        conn,
        "/api/v1/partner-batches",
        batch([open_group(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"})])
      )

      post(conn, "/api/v1/partner-batches", batch([pay("group-ap", 1000)]))

      conn = post(conn, "/api/v1/partner-batches", batch([cancel("group-ap", "2026-10-04")]))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 1000}] =
               json_response(conn, 200)["results"]
    end

    test "an unpaid deposit is simply no longer due and cancellation still applies", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn = post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-11-20")]))

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "a cancelled group rejects later payments, reschedules, and cancellations", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-11-20")]))

      operations = [
        pay("group-81", 100),
        reschedule("group-81", "2026-12-20"),
        cancel("group-81", "2026-12-01")
      ]

      conn = post(conn, "/api/v1/partner-batches", batch(operations))
      results = json_response(conn, 200)["results"]

      assert Enum.all?(
               results,
               &(&1["code"] == "group_not_active" and &1["status"] == "rejected")
             )

      conn = get(conn, "/api/v1/groups/group-81")
      assert %{"data" => %{"revision" => 2}} = json_response(conn, 200)
    end
  end

  describe "revision contract" do
    test "every applied operation increments the revision exactly once", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      revisions =
        for {op, index} <-
              Enum.with_index([
                pay("group-81", 100),
                pay("group-81", 100, %{"operation_id" => "op-pay-second"}),
                reschedule("group-81", "2026-12-20")
              ]) do
          conn = post(conn, "/api/v1/partner-batches", batch([op]))
          [%{"status" => status, "revision" => revision}] = json_response(conn, 200)["results"]
          {index, status, revision}
        end

      assert [{0, "applied", 2}, {1, "applied", 3}, {2, "applied", 4}] = revisions
    end

    test "stale revisions are rejected with the documented fields and leave the group unchanged",
         %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 100)]))

      op = pay("group-81", 100, %{"expected_revision" => 1})
      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] =
               json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 100}} =
               json_response(conn, 200)
    end

    test "a matching expected_revision applies", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      op = pay("group-81", 100, %{"expected_revision" => 1})
      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]
    end

    test "existence is resolved before comparing revisions", %{conn: conn} do
      op = pay("ghost", 100, %{"expected_revision" => 3})
      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               json_response(conn, 200)["results"]
    end

    test "a stale revision is rejected before other domain validation", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 100)]))

      op = pay("group-81", 999_999, %{"expected_revision" => 1})
      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      assert [%{"status" => "rejected", "code" => "stale_revision"}] =
               json_response(conn, 200)["results"]
    end

    test "open_group does not use expected_revision", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      op = open_group(%{"group_id" => "group-two", "expected_revision" => 99})
      conn = post(conn, "/api/v1/partner-batches", batch([op]))

      assert [%{"status" => "applied", "revision" => 1}] = json_response(conn, 200)["results"]
    end
  end

  describe "batch processing" do
    test "operations observe earlier operations in the same batch", %{conn: conn} do
      operations = [
        open_group(),
        pay("group-81", 19500),
        cancel("group-81", "2026-11-20")
      ]

      conn = post(conn, "/api/v1/partner-batches", batch(operations))
      results = json_response(conn, 200)["results"]

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 2},
               %{
                 "status" => "applied",
                 "refunded_cents" => 19500,
                 "retained_cents" => 0,
                 "revision" => 3
               }
             ] = results
    end

    test "a rejected operation does not undo earlier operations or stop later ones", %{conn: conn} do
      operations = [
        open_group(),
        pay("group-81", 999_999),
        pay("group-81", 100)
      ]

      conn = post(conn, "/api/v1/partner-batches", batch(operations))
      results = json_response(conn, 200)["results"]

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{"status" => "applied", "outstanding_deposit_cents" => 19400}
             ] = results
    end
  end

  describe "GET /api/v1/groups/:group_id" do
    test "returns the group with rooms in their original order and all totals", %{conn: conn} do
      op =
        open_group(%{
          "rooms" => [
            %{"room_id" => "room-z", "nightly_rate_cents" => 15000},
            %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
          ]
        })

      post(conn, "/api/v1/partner-batches", batch([op]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 5000)]))

      conn = get(conn, "/api/v1/groups/group-81")
      response = json_response(conn, 200)

      assert %{
               "data" => %{
                 "group_id" => "group-81",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "revision" => 2,
                 "booked_on" => "2026-10-03",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "status" => "active",
                 "rooms" => [
                   %{"room_id" => "room-z", "nightly_rate_cents" => 15000},
                   %{"room_id" => "room-a", "nightly_rate_cents" => 17500}
                 ],
                 "lodging_total_cents" => 97500,
                 "deposit_due_cents" => 19500,
                 "deposit_paid_cents" => 5000,
                 "outstanding_deposit_cents" => 14500
               }
             } = response
    end

    test "returns 404 group_not_found for a missing group", %{conn: conn} do
      conn = get(conn, "/api/v1/groups/ghost")

      assert json_response(conn, 404) == %{"error" => %{"code" => "group_not_found"}}
    end
  end

  describe "GET /api/v1/ledger" do
    test "starts at zero", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               }
             }
    end

    test "payments move between held, refunded, and retained as groups cancel", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))
      post(conn, "/api/v1/partner-batches", batch([pay("group-81", 19500)]))

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 19500,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)

      # Refundable cancellation moves held cash to refunded.
      post(conn, "/api/v1/partner-batches", batch([cancel("group-81", "2026-11-20")]))

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19500,
                 "cash_retained_cents" => 0
               }
             } = json_response(conn, 200)

      # Non-refundable cancellation moves held cash to retained.
      post(
        conn,
        "/api/v1/partner-batches",
        batch([open_group(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"})])
      )

      post(conn, "/api/v1/partner-batches", batch([pay("group-ap", 4000)]))
      post(conn, "/api/v1/partner-batches", batch([cancel("group-ap", "2026-11-20")]))

      conn = get(conn, "/api/v1/ledger")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 19500,
                 "cash_retained_cents" => 4000
               }
             } = json_response(conn, 200)
    end
  end
end
