defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  describe "versioned cancellation policies" do
    test "freezes policy at booking and recomputes the cancellation date on reschedule", %{
      conn: conn
    } do
      operations = [
        open_operation("old", "2026-12-31", "2027-03-15"),
        open_operation("new", "2027-01-01", "2027-03-15"),
        open_operation("advance", "2027-01-01", "2027-03-15", %{
          "rate_plan" => "advance_purchase"
        }),
        %{
          "operation_id" => "move-new",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-02",
          "group_id" => "new",
          "new_arrival_on" => "2027-04-15",
          "expected_revision" => 1
        }
      ]

      %{"results" => results} = post_batch(conn, operations)

      assert Enum.at(results, 3) == %{
               "operation_id" => "move-new",
               "status" => "applied",
               "group_id" => "new",
               "new_arrival_on" => "2027-04-15",
               "new_departure_on" => "2027-04-18",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-16",
               "revision" => 2
             }

      assert get_group("old") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "flex-14",
               "refundable_until" => "2027-03-01"
             }

      assert get_group("new") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "flex-30",
               "refundable_until" => "2027-03-16"
             }

      assert get_group("advance") |> Map.take(["policy_version", "refundable_until"]) == %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             }
    end

    test "uses each policy's inclusive refundable boundary", %{conn: conn} do
      operations = [
        open_operation("old", "2026-12-31", "2027-03-15"),
        payment_operation("old", 100),
        cancel_operation("old", "2027-03-01", 2),
        open_operation("new", "2027-01-01", "2027-03-15"),
        payment_operation("new", 200),
        cancel_operation("new", "2027-02-13", 2)
      ]

      %{"results" => results} = post_batch(conn, operations)
      assert Enum.at(results, 2)["refunded_cents"] == 100
      assert Enum.at(results, 5)["refunded_cents"] == 200
    end
  end

  describe "hotel credit issuance and reads" do
    test "converts refundable cash with a rounded bonus and expires after day 365", %{conn: conn} do
      operations = [
        open_operation("source", "2026-09-01", "2026-12-15"),
        payment_operation("source", 105),
        cancel_operation("source", "2026-10-05", 2, %{"refund_method" => "hotel_credit"})
      ]

      %{"results" => results} = post_batch(conn, operations)

      assert Enum.at(results, 2) == %{
               "operation_id" => "cancel-source",
               "status" => "applied",
               "group_id" => "source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 116,
               "revision" => 3
             }

      assert get_credit("guest-22", "2027-10-05") == %{
               "guest_id" => "guest-22",
               "available_cents" => 116,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 116,
                   "expires_on" => "2027-10-05"
                 }
               ]
             }

      assert get_credit("guest-22", "2027-10-06")["available_cents"] == 0

      assert get_ledger("2027-10-05") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 105,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 116,
               "credit_shortfall_cents" => 0
             }

      assert get_ledger("2027-10-06")["credit_liability_cents"] == 0
    end

    test "rejects hotel credit for a non-refundable cancellation without changing state", %{
      conn: conn
    } do
      operations = [
        open_operation("advance", "2027-01-01", "2027-03-15", %{
          "rate_plan" => "advance_purchase"
        }),
        payment_operation("advance", 500),
        cancel_operation("advance", "2027-01-02", 2, %{"refund_method" => "hotel_credit"})
      ]

      %{"results" => results} = post_batch(conn, operations)

      assert Enum.at(results, 2) == %{
               "operation_id" => "cancel-advance",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      assert get_group("advance") |> Map.take(["status", "revision"]) == %{
               "status" => "active",
               "revision" => 2
             }

      assert get_ledger("2027-01-02")["cash_held_cents"] == 500
    end
  end

  describe "applying and settling hotel credit" do
    test "consumes equal-expiry lots by source id and restores their provenance", %{conn: conn} do
      operations =
        credit_source_operations("source-z", "z-source", 100) ++
          credit_source_operations("source-a", "a-source", 100) ++
          [
            open_operation("target", "2026-10-01", "2026-12-20"),
            credit_operation("target", 110, "2026-10-06", 1),
            cancel_operation("target", "2026-10-07", 2)
          ]

      %{"results" => results} = post_batch(conn, operations)
      assert Enum.at(results, 8)["status"] == "applied"
      assert Enum.at(results, 8)["credit_issued_cents"] == 0

      assert get_credit("guest-22", "2026-10-07")["lots"] == [
               %{
                 "source_operation_id" => "a-source",
                 "remaining_cents" => 110,
                 "expires_on" => "2027-10-05"
               },
               %{
                 "source_operation_id" => "z-source",
                 "remaining_cents" => 110,
                 "expires_on" => "2027-10-05"
               }
             ]

      assert get_group("target")
             |> Map.take(["deposit_paid_cents", "cash_paid_cents", "credit_paid_cents"]) == %{
               "deposit_paid_cents" => 0,
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 0
             }

      assert get_ledger("2026-10-07")
             |> Map.take(["cash_converted_to_credit_cents", "credit_liability_cents"]) == %{
               "cash_converted_to_credit_cents" => 200,
               "credit_liability_cents" => 220
             }
    end

    test "immediately expires restored credit when its original expiry has passed", %{conn: conn} do
      operations = [
        open_operation("source", "2025-12-01", "2026-02-01"),
        payment_operation("source", 100),
        cancel_operation("source", "2026-01-01", 2, %{"refund_method" => "hotel_credit"}),
        open_operation("target", "2026-01-02", "2027-02-01"),
        credit_operation("target", 110, "2027-01-01", 1),
        cancel_operation("target", "2027-01-02", 2)
      ]

      %{"results" => results} = post_batch(conn, operations)
      assert Enum.at(results, 4)["status"] == "applied"
      assert Enum.at(results, 5)["status"] == "applied"
      assert get_credit("guest-22", "2027-01-02")["available_cents"] == 0
      assert get_ledger("2027-01-02")["credit_liability_cents"] == 0
    end

    test "consumes applied credit on non-refundable cancellation", %{conn: conn} do
      operations =
        credit_source_operations("source", "source-credit", 100) ++
          [
            open_operation("target", "2026-10-01", "2026-12-20", %{
              "rate_plan" => "advance_purchase"
            }),
            credit_operation("target", 100, "2026-10-06", 1),
            cancel_operation("target", "2026-10-07", 2, %{
              "operation_id" => "unavailable-method",
              "refund_method" => "hotel_credit"
            }),
            cancel_operation("target", "2026-10-07", 2)
          ]

      %{"results" => results} = post_batch(conn, operations)
      assert Enum.at(results, 5)["code"] == "refund_method_not_available"
      assert Enum.at(results, 6)["status"] == "applied"
      assert Enum.at(results, 6)["retained_cents"] == 0
      assert get_group("target")["revision"] == 3
      assert get_credit("guest-22", "2026-10-07")["available_cents"] == 10
      assert get_ledger("2026-10-07")["credit_liability_cents"] == 10
    end

    test "validates revisions and payment limits before consuming any credit", %{conn: conn} do
      operations =
        credit_source_operations("source", "source-credit", 100) ++
          [
            open_operation("target", "2026-10-01", "2026-12-20"),
            credit_operation("target", 999_999, "2026-10-06", 0),
            credit_operation("target", 999_999, "2026-10-06", 1, %{
              "operation_id" => "too-large"
            }),
            credit_operation("target", 111, "2026-10-06", 1, %{
              "operation_id" => "insufficient"
            }),
            credit_operation("target", 100, "2026-10-06", 1, %{
              "operation_id" => "valid"
            })
          ]

      %{"results" => results} = post_batch(conn, operations)

      assert Enum.at(results, 4)["code"] == "stale_revision"
      assert Enum.at(results, 5)["code"] == "payment_exceeds_outstanding"
      assert Enum.at(results, 6)["code"] == "insufficient_credit"
      assert Enum.at(results, 7)["status"] == "applied"
      assert Enum.at(results, 7)["revision"] == 2
      assert get_credit("guest-22", "2026-10-06")["available_cents"] == 10
    end
  end

  defp post_batch(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
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

  defp get_ledger(on) do
    build_conn()
    |> get("/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp open_operation(group_id, booked_on, arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => booked_on,
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => arrival_on,
        "departure_on" => Date.add(Date.from_iso8601!(arrival_on), 3) |> Date.to_iso8601(),
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      },
      overrides
    )
  end

  defp payment_operation(group_id, amount) do
    %{
      "operation_id" => "pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-01-01",
      "group_id" => group_id,
      "amount_cents" => amount,
      "expected_revision" => 1
    }
  end

  defp cancel_operation(group_id, occurred_on, expected_revision, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "expected_revision" => expected_revision
      },
      overrides
    )
  end

  defp credit_operation(group_id, amount, occurred_on, expected_revision, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount,
        "expected_revision" => expected_revision
      },
      overrides
    )
  end

  defp credit_source_operations(group_id, cancellation_id, cash) do
    [
      open_operation(group_id, "2026-09-01", "2026-12-15"),
      payment_operation(group_id, cash),
      cancel_operation(group_id, "2026-10-05", 2, %{
        "operation_id" => cancellation_id,
        "refund_method" => "hotel_credit"
      })
    ]
  end
end
