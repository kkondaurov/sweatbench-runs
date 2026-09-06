defmodule GroupStayWeb.CancellationEconomicsControllerTest do
  use GroupStayWeb.ConnCase

  describe "policy versions" do
    test "fixes policy at booking and recomputes the inclusive deadline on reschedule", %{
      conn: conn
    } do
      operations = [
        open_operation("old", "guest-1", %{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        open_operation("new", "guest-2", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-01",
          "departure_on" => "2027-03-02"
        }),
        open_operation("advance", "guest-3", %{"rate_plan" => "advance_purchase"}),
        reschedule_operation("old", %{"new_arrival_on" => "2027-04-01"})
      ]

      assert %{"results" => [_, _, _, moved]} =
               conn |> post_batch(operations) |> json_response(200)

      assert moved["policy_version"] == "flex-14"
      assert moved["refundable_until"] == "2027-03-18"

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-03-18"
               }
             } = get_group("old")

      assert %{
               "data" => %{
                 "policy_version" => "flex-30",
                 "refundable_until" => "2027-01-30"
               }
             } = get_group("new")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get_group("advance")
    end

    test "treats cancellation on each policy deadline as refundable", %{conn: conn} do
      operations = [
        open_operation("old", "guest-1", %{
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-02-14",
          "departure_on" => "2027-02-15"
        }),
        payment_operation("old", 100),
        cancel_operation("old", %{"occurred_on" => "2027-01-31"}),
        open_operation("new", "guest-2", %{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-02-14",
          "departure_on" => "2027-02-15"
        }),
        payment_operation("new", 100),
        cancel_operation("new", %{"occurred_on" => "2027-01-15"})
      ]

      assert %{"results" => [_, _, old_cancel, _, _, new_cancel]} =
               conn |> post_batch(operations) |> json_response(200)

      assert old_cancel["refunded_cents"] == 100
      assert new_cancel["refunded_cents"] == 100
    end
  end

  describe "hotel credit" do
    test "converts refundable cash with a rounded bonus and exposes dated reads", %{conn: conn} do
      operations = [
        open_operation("source", "guest-1"),
        payment_operation("source", 1_005),
        cancel_operation("source", %{
          "occurred_on" => "2027-01-01",
          "refund_method" => "hotel_credit"
        })
      ]

      assert %{"results" => [_, _, cancelled]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled == %{
               "operation_id" => "cancel-source",
               "status" => "applied",
               "group_id" => "source",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 1_106,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "guest_id" => "guest-1",
                 "available_cents" => 1_106,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-source",
                     "remaining_cents" => 1_106,
                     "expires_on" => "2028-01-01"
                   }
                 ]
               }
             } = get_credit("guest-1", "2028-01-01")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get_credit("guest-1", "2028-01-02")

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 1_005,
                 "credit_liability_cents" => 1_106
               }
             } = get_ledger("2028-01-01")

      assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger("2028-01-02")
    end

    test "rejects hotel credit for non-refundable cancellations without advancing revision", %{
      conn: conn
    } do
      operations = [
        open_operation("advance", "guest-1", %{"rate_plan" => "advance_purchase"}),
        payment_operation("advance", 100),
        cancel_operation("advance", %{
          "refund_method" => "hotel_credit",
          "expected_revision" => 9
        }),
        cancel_operation("advance", %{
          "operation_id" => "unavailable",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        })
      ]

      assert %{"results" => [_, _, stale, unavailable]} =
               conn |> post_batch(operations) |> json_response(200)

      assert stale["code"] == "stale_revision"
      assert unavailable["code"] == "refund_method_not_available"
      assert %{"data" => %{"status" => "active", "revision" => 2}} = get_group("advance")
      assert %{"data" => %{"cash_held_cents" => 100}} = get_ledger("2027-01-01")
    end

    test "applies earliest-expiring lots and source identifiers in order", %{conn: conn} do
      operations =
        issue_credit_operations("later", "guest-1", "2027-01-02", 100) ++
          issue_credit_operations("b", "guest-1", "2027-01-01", 100) ++
          issue_credit_operations("a", "guest-1", "2027-01-01", 100) ++
          [
            open_operation("target", "guest-1", %{
              "occurred_on" => "2027-01-03",
              "arrival_on" => "2027-06-01",
              "departure_on" => "2027-06-02"
            }),
            apply_credit_operation("target", 150, %{"occurred_on" => "2027-01-03"})
          ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert List.last(results)["status"] == "applied"

      assert %{
               "data" => %{
                 "available_cents" => 180,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-b",
                     "remaining_cents" => 70,
                     "expires_on" => "2028-01-01"
                   },
                   %{
                     "source_operation_id" => "cancel-later",
                     "remaining_cents" => 110,
                     "expires_on" => "2028-01-02"
                   }
                 ]
               }
             } = get_credit("guest-1", "2027-01-03")

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 150,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 150,
                 "outstanding_deposit_cents" => 1_850
               }
             } = get_group("target")

      assert %{"data" => %{"credit_liability_cents" => 150}} =
               get_ledger("2029-01-01")
    end

    test "settles mixed funding without applying a second bonus to restored credit", %{conn: conn} do
      operations =
        issue_credit_operations("source", "guest-1", "2027-01-01", 1_000) ++
          [
            open_operation("target", "guest-1", %{
              "occurred_on" => "2027-01-02",
              "arrival_on" => "2027-12-01",
              "departure_on" => "2027-12-02"
            }),
            payment_operation("target", 500),
            apply_credit_operation("target", 500),
            cancel_operation("target", %{
              "occurred_on" => "2027-06-01",
              "refund_method" => "hotel_credit"
            })
          ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert List.last(results)["credit_issued_cents"] == 550

      assert %{
               "data" => %{
                 "available_cents" => 1_650,
                 "lots" => [
                   %{"source_operation_id" => "cancel-source", "remaining_cents" => 1_100},
                   %{"source_operation_id" => "cancel-target", "remaining_cents" => 550}
                 ]
               }
             } = get_credit("guest-1", "2027-06-01")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 1_500,
                 "credit_liability_cents" => 1_650
               }
             } = get_ledger("2027-06-01")
    end

    test "keeps credit expiry sortable beyond the four-digit calendar range", %{conn: conn} do
      operations = [
        open_operation("future", "guest-future", %{
          "arrival_on" => "9999-12-30",
          "departure_on" => "9999-12-31"
        }),
        payment_operation("future", 100),
        cancel_operation("future", %{
          "occurred_on" => "9999-11-30",
          "refund_method" => "hotel_credit"
        })
      ]

      assert %{"results" => [_, _, %{"credit_issued_cents" => 110}]} =
               conn |> post_batch(operations) |> json_response(200)

      assert %{
               "data" => %{
                 "available_cents" => 110,
                 "lots" => [%{"expires_on" => "10000-11-29"}]
               }
             } = get_credit("guest-future", "10000-11-29")

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get_ledger("10000-11-30")
    end

    test "expires late restorations and consumes credit on non-refundable cancellation", %{
      conn: conn
    } do
      late_restore =
        issue_credit_operations("late-source", "guest-late", "2027-01-01", 100) ++
          [
            open_operation("late-target", "guest-late", %{
              "occurred_on" => "2027-01-02",
              "arrival_on" => "2029-01-01",
              "departure_on" => "2029-01-02"
            }),
            apply_credit_operation("late-target", 110),
            cancel_operation("late-target", %{"occurred_on" => "2028-01-02"})
          ]

      consumed =
        issue_credit_operations("fee-source", "guest-fee", "2027-01-01", 100) ++
          [
            open_operation("fee-target", "guest-fee", %{
              "rate_plan" => "advance_purchase",
              "occurred_on" => "2027-01-02"
            }),
            apply_credit_operation("fee-target", 110),
            cancel_operation("fee-target", %{"occurred_on" => "2027-01-03"})
          ]

      assert %{"results" => results} =
               conn |> post_batch(late_restore ++ consumed) |> json_response(200)

      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"data" => %{"available_cents" => 0}} =
               get_credit("guest-late", "2028-01-02")

      assert %{"data" => %{"available_cents" => 0}} =
               get_credit("guest-fee", "2027-01-03")

      assert %{"data" => %{"credit_liability_cents" => 0}} = get_ledger("2028-01-02")
    end

    test "validates credit applications after revision and before changing balances", %{
      conn: conn
    } do
      operations =
        issue_credit_operations("source", "guest-1", "2027-01-01", 100) ++
          [
            open_operation("target", "guest-1", %{"occurred_on" => "2027-01-02"}),
            apply_credit_operation("target", -1, %{
              "operation_id" => "credit-stale",
              "expected_revision" => 9
            }),
            apply_credit_operation("target", 2_001, %{
              "operation_id" => "credit-excessive"
            }),
            apply_credit_operation("target", 111, %{
              "operation_id" => "credit-insufficient"
            }),
            apply_credit_operation("target", 110, %{
              "operation_id" => "credit-applied",
              "expected_revision" => 1
            })
          ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      [stale, excessive, insufficient, applied] = Enum.take(results, -4)

      assert stale["code"] == "stale_revision"
      assert excessive["code"] == "payment_exceeds_outstanding"
      assert insufficient["code"] == "insufficient_credit"
      assert applied["revision"] == 2
      assert %{"data" => %{"available_cents" => 0}} = get_credit("guest-1", "2027-01-03")
    end
  end

  describe "dated reads" do
    test "returns empty credit for an unknown guest and rejects malformed dates", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/guests/unknown/credit?on=2027-01-01"), 200) == %{
               "data" => %{"guest_id" => "unknown", "available_cents" => 0, "lots" => []}
             }

      assert json_response(get(build_conn(), "/api/v1/ledger?on=bad"), 422) == %{
               "error" => %{"code" => "invalid_date"}
             }

      assert json_response(get(build_conn(), "/api/v1/guests/unknown/credit?on=bad"), 422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_group(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp get_credit(guest_id, on) do
    build_conn() |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}") |> json_response(200)
  end

  defp get_ledger(on) do
    build_conn() |> get("/api/v1/ledger?on=#{on}") |> json_response(200)
  end

  defp issue_credit_operations(group_id, guest_id, cancelled_on, cash) do
    [
      open_operation(group_id, guest_id, %{
        "arrival_on" => "2029-01-01",
        "departure_on" => "2029-01-02"
      }),
      payment_operation(group_id, cash),
      cancel_operation(group_id, %{
        "occurred_on" => cancelled_on,
        "refund_method" => "hotel_credit"
      })
    ]
  end

  defp open_operation(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp payment_operation(group_id, amount) do
    %{
      "operation_id" => "pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp apply_credit_operation(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-01-03",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reschedule_operation(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "move-#{group_id}",
        "type" => "reschedule_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "new_arrival_on" => "2027-04-01"
      },
      overrides
    )
  end

  defp cancel_operation(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id
      },
      overrides
    )
  end
end
