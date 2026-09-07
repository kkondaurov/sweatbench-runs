defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Credits.{CreditAllocation, CreditLot}
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  describe "policy versions" do
    test "fixes policy at booking and recomputes only the deadline when rescheduled", %{
      conn: conn
    } do
      operations = [
        open_operation(%{"group_id" => "old-flex", "operation_id" => "old"}),
        open_operation(%{
          "group_id" => "new-flex",
          "operation_id" => "new",
          "occurred_on" => "2027-01-01"
        }),
        open_operation(%{
          "group_id" => "advance",
          "operation_id" => "advance",
          "rate_plan" => "advance_purchase"
        }),
        reschedule_operation(%{
          "group_id" => "new-flex",
          "operation_id" => "move-new",
          "occurred_on" => "2027-01-02",
          "new_arrival_on" => "2027-04-10",
          "expected_revision" => 1
        })
      ]

      results = post_batch(conn, operations)

      assert Enum.at(results, 3) == %{
               "operation_id" => "move-new",
               "status" => "applied",
               "group_id" => "new-flex",
               "new_arrival_on" => "2027-04-10",
               "new_departure_on" => "2027-04-13",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-11",
               "revision" => 2
             }

      assert get_group("old-flex") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-02-24"
             }

      assert get_group("new-flex") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-11"
             }

      assert get_group("advance") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
    end

    test "makes the 30-day boundary inclusive", %{conn: conn} do
      operations = [
        open_operation(%{
          "group_id" => "at-boundary",
          "operation_id" => "open-at",
          "occurred_on" => "2027-01-01"
        }),
        cash_operation(%{"group_id" => "at-boundary", "amount_cents" => 1_000}),
        cancel_operation(%{"group_id" => "at-boundary", "occurred_on" => "2027-02-08"}),
        open_operation(%{
          "group_id" => "after-boundary",
          "operation_id" => "open-after",
          "occurred_on" => "2027-01-01"
        }),
        cash_operation(%{"group_id" => "after-boundary", "amount_cents" => 1_000}),
        cancel_operation(%{"group_id" => "after-boundary", "occurred_on" => "2027-02-09"})
      ]

      results = post_batch(conn, operations)

      assert Enum.at(results, 2) |> Map.take(["refunded_cents", "retained_cents"]) == %{
               "refunded_cents" => 1_000,
               "retained_cents" => 0
             }

      assert Enum.at(results, 5) |> Map.take(["refunded_cents", "retained_cents"]) == %{
               "refunded_cents" => 0,
               "retained_cents" => 1_000
             }
    end
  end

  describe "issuing credit" do
    test "converts refundable cash with the rounded bonus and reports expiry", %{conn: conn} do
      results =
        post_batch(conn, [
          open_operation(),
          cash_operation(%{"amount_cents" => 5}),
          cancel_operation(%{
            "operation_id" => "credit-cancel",
            "occurred_on" => "2027-01-05",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          })
        ])

      assert Enum.at(results, 2) == %{
               "operation_id" => "credit-cancel",
               "status" => "applied",
               "group_id" => "group-1",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 6,
               "revision" => 3
             }

      assert get_credit("guest-22", "2028-01-05") == %{
               "guest_id" => "guest-22",
               "available_cents" => 6,
               "lots" => [
                 %{
                   "source_operation_id" => "credit-cancel",
                   "remaining_cents" => 6,
                   "expires_on" => "2028-01-05"
                 }
               ]
             }

      assert get_credit("guest-22", "2028-01-06")["available_cents"] == 0

      assert get_ledger("2028-01-05") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5,
               "credit_liability_cents" => 6
             }

      assert get_ledger("2028-01-06")["credit_liability_cents"] == 0
    end

    test "rejects hotel credit for non-refundable cancellation after revision checking", %{
      conn: conn
    } do
      results =
        post_batch(conn, [
          open_operation(%{"rate_plan" => "advance_purchase"}),
          cash_operation(%{"amount_cents" => 500}),
          cancel_operation(%{
            "operation_id" => "stale-cancel",
            "refund_method" => "hotel_credit",
            "expected_revision" => 1
          }),
          cancel_operation(%{
            "operation_id" => "unavailable",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          })
        ])

      assert Enum.at(results, 2)["code"] == "stale_revision"
      assert Enum.at(results, 3)["code"] == "refund_method_not_available"

      group = Repo.get!(Group, "group-1")
      assert group.status == :active
      assert group.revision == 2
      assert group.cash_paid_cents == 500
      assert get_ledger()["cash_held_cents"] == 500
    end
  end

  describe "applying and settling credit" do
    test "bonuses only cash and restores prior credit without a second bonus", %{conn: conn} do
      insert_lot("guest-22", "original", 1_000, ~D[2028-01-01])

      results =
        post_batch(conn, [
          open_operation(),
          credit_operation(%{"amount_cents" => 400}),
          cash_operation(%{"amount_cents" => 500}),
          cancel_operation(%{
            "operation_id" => "combined-cancel",
            "occurred_on" => "2027-01-02",
            "refund_method" => "hotel_credit",
            "expected_revision" => 3
          })
        ])

      assert Enum.at(results, 3)
             |> Map.take(["credit_issued_cents", "refunded_cents", "retained_cents"]) == %{
               "credit_issued_cents" => 550,
               "refunded_cents" => 0,
               "retained_cents" => 0
             }

      assert get_credit("guest-22", "2027-01-02") == %{
               "guest_id" => "guest-22",
               "available_cents" => 1_550,
               "lots" => [
                 %{
                   "source_operation_id" => "original",
                   "remaining_cents" => 1_000,
                   "expires_on" => "2028-01-01"
                 },
                 %{
                   "source_operation_id" => "combined-cancel",
                   "remaining_cents" => 550,
                   "expires_on" => "2028-01-02"
                 }
               ]
             }

      assert get_ledger("2027-01-02")
             |> Map.take(["cash_converted_to_credit_cents", "credit_liability_cents"]) == %{
               "cash_converted_to_credit_cents" => 500,
               "credit_liability_cents" => 1_550
             }
    end

    test "consumes lots by expiry and source identifier and restores them on refund", %{
      conn: conn
    } do
      insert_lot("guest-22", "z-source", 100, ~D[2027-06-01])
      insert_lot("guest-22", "a-source", 100, ~D[2027-06-01])
      insert_lot("guest-22", "early-source", 100, ~D[2027-05-01])

      results =
        post_batch(conn, [
          open_operation(),
          credit_operation(%{"amount_cents" => 250, "expected_revision" => 1}),
          credit_operation(%{
            "operation_id" => "not-enough",
            "amount_cents" => 51,
            "expected_revision" => 2
          }),
          credit_operation(%{
            "operation_id" => "stale",
            "amount_cents" => 1,
            "expected_revision" => 1
          })
        ])

      assert Enum.at(results, 1) == %{
               "operation_id" => "use-credit",
               "status" => "applied",
               "group_id" => "group-1",
               "amount_cents" => 250,
               "outstanding_deposit_cents" => 19_250,
               "revision" => 2
             }

      assert Enum.at(results, 2)["code"] == "insufficient_credit"
      assert Enum.at(results, 3)["code"] == "stale_revision"

      assert get_credit("guest-22", "2027-01-01")["lots"] == [
               %{
                 "source_operation_id" => "z-source",
                 "remaining_cents" => 50,
                 "expires_on" => "2027-06-01"
               }
             ]

      assert allocation_sources("group-1") == [
               {"a-source", 100},
               {"early-source", 100},
               {"z-source", 50}
             ]

      group = get_group("group-1")
      assert group["deposit_paid_cents"] == 250
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 250
      assert group["revision"] == 2
      assert get_ledger("2030-01-01")["credit_liability_cents"] == 250

      [cancelled] =
        post_batch(build_conn(), [
          cancel_operation(%{"occurred_on" => "2027-02-01", "expected_revision" => 2})
        ])

      assert cancelled["credit_issued_cents"] == 0
      assert get_credit("guest-22", "2027-02-01")["available_cents"] == 300
      assert get_ledger("2027-02-01")["credit_liability_cents"] == 300
    end

    test "drops restored credit whose original expiry passed while applied", %{conn: conn} do
      insert_lot("guest-22", "expiring", 500, ~D[2027-01-10])

      results =
        post_batch(conn, [
          open_operation(%{"arrival_on" => "2027-12-10", "departure_on" => "2027-12-13"}),
          credit_operation(%{"occurred_on" => "2027-01-10", "amount_cents" => 500})
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert get_ledger("2030-01-01")["credit_liability_cents"] == 500

      [cancelled] =
        post_batch(build_conn(), [
          cancel_operation(%{"occurred_on" => "2027-01-11", "expected_revision" => 2})
        ])

      assert cancelled["status"] == "applied"
      assert get_credit("guest-22", "2027-01-10")["available_cents"] == 0
      assert get_ledger("2027-01-11")["credit_liability_cents"] == 0
    end

    test "consumes applied credit and retains only cash on non-refundable cancellation", %{
      conn: conn
    } do
      insert_lot("guest-22", "source", 1_000, ~D[2028-01-01])

      results =
        post_batch(conn, [
          open_operation(%{"rate_plan" => "advance_purchase"}),
          credit_operation(%{"amount_cents" => 400}),
          cash_operation(%{"amount_cents" => 300}),
          cancel_operation(%{"expected_revision" => 3})
        ])

      assert Enum.at(results, 3) |> Map.take(["refunded_cents", "retained_cents"]) == %{
               "refunded_cents" => 0,
               "retained_cents" => 300
             }

      assert get_credit("guest-22", "2027-01-01")["available_cents"] == 600

      assert get_ledger("2027-01-01") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 300,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 600
             }
    end

    test "uses payment validation before checking the available balance", %{conn: conn} do
      insert_lot("guest-22", "large", 50_000, ~D[2028-01-01])

      results =
        post_batch(conn, [
          open_operation(),
          credit_operation(%{"operation_id" => "zero", "amount_cents" => 0}),
          credit_operation(%{"operation_id" => "too-large", "amount_cents" => 19_501}),
          credit_operation(%{"operation_id" => "bad-date", "occurred_on" => "bad"})
        ])

      assert Enum.map(Enum.drop(results, 1), & &1["code"]) == [
               "invalid_amount",
               "payment_exceeds_outstanding",
               "invalid_operation"
             ]

      assert Repo.get!(Group, "group-1").revision == 1
    end

    test "does not apply a lot after its inclusive expiry date", %{conn: conn} do
      insert_lot("guest-22", "expired", 500, ~D[2027-01-01])

      results =
        post_batch(conn, [
          open_operation(),
          credit_operation(%{"occurred_on" => "2027-01-02", "amount_cents" => 500})
        ])

      assert Enum.at(results, 1)["code"] == "insufficient_credit"
      assert Repo.get!(Group, "group-1").revision == 1
      assert get_credit("guest-22", "2027-01-02")["lots"] == []
      assert get_ledger("2027-01-02")["credit_liability_cents"] == 0
    end
  end

  describe "dated reads" do
    test "returns an empty credit account and rejects unusable report dates", %{conn: conn} do
      assert get(conn, "/api/v1/guests/unknown/credit") |> json_response(200) == %{
               "data" => %{"guest_id" => "unknown", "available_cents" => 0, "lots" => []}
             }

      assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=nope")
             |> json_response(422) == %{"error" => %{"code" => "invalid_date"}}

      assert get(build_conn(), "/api/v1/ledger?on=nope") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  defp open_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-12-31",
        "group_id" => "group-1",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 32_500}]
      },
      overrides
    )
  end

  defp cash_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "cash-payment",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "use-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-1",
        "amount_cents" => 100
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "move",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-1",
        "new_arrival_on" => "2027-04-10"
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => "group-1"
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_group(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_credit(guest_id, on) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger(on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"

    build_conn()
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp insert_lot(guest_id, source_operation_id, remaining_cents, expires_on) do
    %CreditLot{}
    |> CreditLot.creation_changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: expires_on
    })
    |> Repo.insert!()
  end

  defp allocation_sources(group_id) do
    Repo.all(
      from allocation in CreditAllocation,
        join: lot in assoc(allocation, :credit_lot),
        where: allocation.group_id == ^group_id,
        order_by: lot.source_operation_id,
        select: {lot.source_operation_id, allocation.amount_cents}
    )
  end
end
