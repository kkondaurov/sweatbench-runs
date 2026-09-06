defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  describe "fixed cancellation policies" do
    test "selects policy at booking boundaries and recomputes only the cutoff on reschedule", %{
      conn: conn
    } do
      operations = [
        open_operation(%{
          "operation_id" => "open-old",
          "group_id" => "old-flex",
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-31",
          "departure_on" => "2027-04-01"
        }),
        open_operation(%{
          "operation_id" => "open-new",
          "group_id" => "new-flex",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-31",
          "departure_on" => "2027-04-01"
        }),
        open_operation(%{
          "operation_id" => "open-advance",
          "group_id" => "advance",
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-31",
          "departure_on" => "2027-04-01"
        }),
        reschedule_operation(%{
          "group_id" => "old-flex",
          "occurred_on" => "2027-02-01",
          "new_arrival_on" => "2027-04-30",
          "expected_revision" => 1
        })
      ]

      assert %{"results" => [_, _, _, moved]} =
               conn |> post_batch(operations) |> json_response(200)

      assert moved == %{
               "operation_id" => "move-1",
               "status" => "applied",
               "group_id" => "old-flex",
               "new_arrival_on" => "2027-04-30",
               "new_departure_on" => "2027-05-01",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-04-16",
               "revision" => 2
             }

      assert %{
               "data" => %{
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-04-16",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } = get_group("old-flex")

      assert %{"data" => %{"policy_version" => "flex-30", "refundable_until" => "2027-03-01"}} =
               get_group("new-flex")

      assert %{
               "data" => %{
                 "policy_version" => "advance-nonrefundable",
                 "refundable_until" => nil
               }
             } = get_group("advance")
    end

    test "treats each policy cutoff as inclusive", %{conn: conn} do
      operations = [
        open_operation(%{
          "operation_id" => "open-14-exact",
          "group_id" => "flex-14-exact",
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-03-31",
          "departure_on" => "2027-04-01"
        }),
        cash_operation(%{"group_id" => "flex-14-exact", "amount_cents" => 10}),
        cancel_operation(%{
          "group_id" => "flex-14-exact",
          "occurred_on" => "2027-03-17"
        }),
        open_operation(%{
          "operation_id" => "open-30-late",
          "group_id" => "flex-30-late",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-03-31",
          "departure_on" => "2027-04-01"
        }),
        cash_operation(%{"group_id" => "flex-30-late", "amount_cents" => 10}),
        cancel_operation(%{"group_id" => "flex-30-late", "occurred_on" => "2027-03-02"})
      ]

      assert %{"results" => [_, _, exact, _, _, late]} =
               conn |> post_batch(operations) |> json_response(200)

      assert exact["refunded_cents"] == 10
      assert exact["retained_cents"] == 0
      assert exact["credit_issued_cents"] == 0
      assert late["refunded_cents"] == 0
      assert late["retained_cents"] == 10
    end
  end

  describe "hotel credit lifecycle" do
    test "settles mixed funding into restored original credit plus one rounded cash bonus", %{
      conn: conn
    } do
      issue_credit(conn, "mixed-source", "cancel-mixed-source", 100, "2027-01-01")

      operations = [
        open_operation(%{
          "operation_id" => "open-mixed-target",
          "group_id" => "mixed-target",
          "occurred_on" => "2027-02-01",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02"
        }),
        cash_operation(%{
          "group_id" => "mixed-target",
          "amount_cents" => 5,
          "occurred_on" => "2027-02-02"
        }),
        credit_operation(%{
          "operation_id" => "credit-mixed-1",
          "group_id" => "mixed-target",
          "amount_cents" => 30,
          "occurred_on" => "2027-02-02"
        }),
        credit_operation(%{
          "operation_id" => "credit-mixed-2",
          "group_id" => "mixed-target",
          "amount_cents" => 40,
          "occurred_on" => "2027-02-02"
        }),
        cancel_operation(%{
          "operation_id" => "cancel-mixed-target",
          "group_id" => "mixed-target",
          "occurred_on" => "2027-03-01",
          "refund_method" => "hotel_credit"
        })
      ]

      assert %{"results" => [_, _, _, _, cancelled]} =
               build_conn() |> post_batch(operations) |> json_response(200)

      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 0
      assert cancelled["credit_issued_cents"] == 6

      assert %{
               "data" => %{
                 "available_cents" => 116,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-mixed-source",
                     "remaining_cents" => 110
                   },
                   %{
                     "source_operation_id" => "cancel-mixed-target",
                     "remaining_cents" => 6
                   }
                 ]
               }
             } = get_credit("guest-22", "2027-03-01")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 105,
                 "credit_liability_cents" => 116
               }
             } = get_ledger("2027-03-01")
    end

    test "issues rounded bonus credit, consumes lots in policy order, and restores allocations",
         %{
           conn: conn
         } do
      issue_credit(conn, "early", "cancel-early", 50, "2027-01-01")
      issue_credit(build_conn(), "source-z", "cancel-z", 100, "2027-02-01")
      issue_credit(build_conn(), "source-a", "cancel-a", 200, "2027-02-01")

      operations = [
        open_operation(%{
          "operation_id" => "open-target",
          "group_id" => "target",
          "occurred_on" => "2027-02-02",
          "arrival_on" => "2027-12-01",
          "departure_on" => "2027-12-02"
        }),
        credit_operation(%{
          "group_id" => "target",
          "amount_cents" => 150,
          "occurred_on" => "2027-03-01",
          "expected_revision" => 1
        })
      ]

      assert %{"results" => [_, applied]} =
               build_conn() |> post_batch(operations) |> json_response(200)

      assert applied == %{
               "operation_id" => "credit-1",
               "status" => "applied",
               "group_id" => "target",
               "amount_cents" => 150,
               "outstanding_deposit_cents" => 19_850,
               "revision" => 2
             }

      assert %{
               "data" => %{
                 "deposit_paid_cents" => 150,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 150
               }
             } = get_group("target")

      assert %{
               "data" => %{
                 "available_cents" => 235,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-a",
                     "remaining_cents" => 125,
                     "expires_on" => "2028-02-01"
                   },
                   %{
                     "source_operation_id" => "cancel-z",
                     "remaining_cents" => 110,
                     "expires_on" => "2028-02-01"
                   }
                 ]
               }
             } = get_credit("guest-22", "2027-03-01")

      assert %{"data" => %{"credit_liability_cents" => 385}} =
               get_ledger("2027-03-01")

      assert %{"results" => [cancelled]} =
               build_conn()
               |> post_batch([
                 cancel_operation(%{
                   "operation_id" => "cancel-target",
                   "group_id" => "target",
                   "occurred_on" => "2027-03-02",
                   "expected_revision" => 2
                 })
               ])
               |> json_response(200)

      assert cancelled["credit_issued_cents"] == 0

      assert %{
               "data" => %{
                 "available_cents" => 385,
                 "lots" => [
                   %{"source_operation_id" => "cancel-early", "remaining_cents" => 55},
                   %{"source_operation_id" => "cancel-a", "remaining_cents" => 220},
                   %{"source_operation_id" => "cancel-z", "remaining_cents" => 110}
                 ]
               }
             } = get_credit("guest-22", "2027-03-02")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 350,
                 "credit_liability_cents" => 385
               }
             } = get_ledger("2027-03-02")
    end

    test "counts applied credit after expiry and drops it when an expired allocation is restored",
         %{
           conn: conn
         } do
      issue_credit(conn, "expiry-source", "cancel-expiry", 100, "2027-01-01")

      operations = [
        open_operation(%{
          "operation_id" => "open-expiry-target",
          "group_id" => "expiry-target",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2028-02-01",
          "departure_on" => "2028-02-02"
        }),
        credit_operation(%{
          "group_id" => "expiry-target",
          "amount_cents" => 70,
          "occurred_on" => "2027-12-31"
        })
      ]

      assert %{"results" => [_, %{"status" => "applied"}]} =
               build_conn() |> post_batch(operations) |> json_response(200)

      assert %{"data" => %{"available_cents" => 40}} =
               get_credit("guest-22", "2028-01-01")

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               get_credit("guest-22", "2028-01-02")

      assert %{"data" => %{"credit_liability_cents" => 70}} =
               get_ledger("2028-01-02")

      assert %{"results" => [%{"status" => "applied", "credit_issued_cents" => 0}]} =
               build_conn()
               |> post_batch([
                 cancel_operation(%{
                   "group_id" => "expiry-target",
                   "occurred_on" => "2028-01-02",
                   "expected_revision" => 2
                 })
               ])
               |> json_response(200)

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               get_ledger("2028-01-02")
    end

    test "rejects hotel credit for nonrefundable cancellation and consumes applied credit on cash settlement",
         %{
           conn: conn
         } do
      issue_credit(conn, "nonref-source", "cancel-source", 100, "2027-04-01")

      operations = [
        open_operation(%{
          "operation_id" => "open-nonref-target",
          "group_id" => "nonref-target",
          "rate_plan" => "advance_purchase",
          "occurred_on" => "2027-04-01",
          "arrival_on" => "2027-10-01",
          "departure_on" => "2027-10-02"
        }),
        credit_operation(%{"group_id" => "nonref-target", "amount_cents" => 70}),
        cash_operation(%{"group_id" => "nonref-target", "amount_cents" => 40}),
        cancel_operation(%{
          "operation_id" => "stale-hotel-cancel",
          "group_id" => "nonref-target",
          "refund_method" => "hotel_credit",
          "expected_revision" => 2
        }),
        cancel_operation(%{
          "operation_id" => "rejected-hotel-cancel",
          "group_id" => "nonref-target",
          "refund_method" => "hotel_credit",
          "expected_revision" => 3
        }),
        cancel_operation(%{
          "operation_id" => "cash-cancel",
          "group_id" => "nonref-target",
          "expected_revision" => 3
        })
      ]

      assert %{"results" => [_, _, _, stale, rejected, cancelled]} =
               build_conn() |> post_batch(operations) |> json_response(200)

      assert stale["code"] == "stale_revision"
      assert rejected["code"] == "refund_method_not_available"
      assert cancelled["revision"] == 4
      assert cancelled["retained_cents"] == 40
      assert cancelled["credit_issued_cents"] == 0

      assert %{"data" => %{"available_cents" => 40}} =
               get_credit("guest-22", "2027-04-02")

      assert %{
               "data" => %{
                 "cash_retained_cents" => 40,
                 "credit_liability_cents" => 40
               }
             } = get_ledger("2027-04-02")
    end

    test "validates credit application and date-sensitive read queries without mutation", %{
      conn: conn
    } do
      assert %{"results" => [_]} =
               conn
               |> post_batch([open_operation(%{"group_id" => "validation-target"})])
               |> json_response(200)

      attempts = [
        credit_operation(%{
          "operation_id" => "stale-invalid",
          "group_id" => "validation-target",
          "amount_cents" => 0,
          "expected_revision" => 0
        }),
        credit_operation(%{
          "operation_id" => "bad-date",
          "group_id" => "validation-target",
          "occurred_on" => "nope"
        }),
        credit_operation(%{
          "operation_id" => "zero",
          "group_id" => "validation-target",
          "amount_cents" => 0
        }),
        credit_operation(%{
          "operation_id" => "too-much",
          "group_id" => "validation-target",
          "amount_cents" => 20_001
        }),
        credit_operation(%{
          "operation_id" => "not-enough",
          "group_id" => "validation-target",
          "amount_cents" => 1
        }),
        cancel_operation(%{
          "operation_id" => "null-method",
          "group_id" => "validation-target",
          "refund_method" => nil
        })
      ]

      assert %{"results" => [stale, bad_date, zero, too_much, not_enough, null_method]} =
               build_conn() |> post_batch(attempts) |> json_response(200)

      assert stale["code"] == "stale_revision"
      assert bad_date["code"] == "invalid_operation"
      assert zero["code"] == "invalid_amount"
      assert too_much["code"] == "payment_exceeds_outstanding"
      assert not_enough["code"] == "insufficient_credit"
      assert null_method["code"] == "invalid_operation"
      assert %{"data" => %{"revision" => 1}} = get_group("validation-target")

      assert get(build_conn(), "/api/v1/ledger?on=not-a-date") |> json_response(422) ==
               %{"error" => %{"code" => "invalid_date"}}

      assert get(build_conn(), "/api/v1/guests/nobody/credit") |> json_response(200) == %{
               "data" => %{"guest_id" => "nobody", "available_cents" => 0, "lots" => []}
             }
    end

    test "ledger totals do not overflow when valid individual balances exceed int64 in aggregate",
         %{
           conn: conn
         } do
      max = 9_223_372_036_854_775_807

      operations =
        Enum.flat_map(["huge-a", "huge-b"], fn group_id ->
          [
            open_operation(%{
              "operation_id" => "open-#{group_id}",
              "group_id" => group_id,
              "rate_plan" => "advance_purchase",
              "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => max}]
            }),
            cash_operation(%{
              "operation_id" => "pay-#{group_id}",
              "group_id" => group_id,
              "amount_cents" => max
            })
          ]
        end)

      assert %{
               "results" => [
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"},
                 %{"status" => "applied"}
               ]
             } =
               conn |> post_batch(operations) |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => held}} = get_ledger("2027-01-01")
      assert held == 2 * max
    end
  end

  defp issue_credit(conn, group_id, cancel_id, cash, cancelled_on) do
    arrival_on = cancelled_on |> Date.from_iso8601!() |> Date.add(60) |> Date.to_iso8601()
    departure_on = cancelled_on |> Date.from_iso8601!() |> Date.add(61) |> Date.to_iso8601()

    operations = [
      open_operation(%{
        "operation_id" => "open-#{group_id}",
        "group_id" => group_id,
        "occurred_on" => cancelled_on,
        "arrival_on" => arrival_on,
        "departure_on" => departure_on
      }),
      cash_operation(%{
        "operation_id" => "pay-#{group_id}",
        "group_id" => group_id,
        "occurred_on" => cancelled_on,
        "amount_cents" => cash
      }),
      cancel_operation(%{
        "operation_id" => cancel_id,
        "group_id" => group_id,
        "occurred_on" => cancelled_on,
        "refund_method" => "hotel_credit"
      })
    ]

    assert %{"results" => [_, _, %{"status" => "applied", "credit_issued_cents" => issued}]} =
             conn |> post_batch(operations) |> json_response(200)

    assert issued == cash + div(cash * 10 + 50, 100)
  end

  defp get_group(group_id),
    do: build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)

  defp get_credit(guest_id, on),
    do: build_conn() |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}") |> json_response(200)

  defp get_ledger(on),
    do: build_conn() |> get("/api/v1/ledger?on=#{on}") |> json_response(200)

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp open_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "open-1",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100_000}]
      },
      overrides
    )
  end

  defp cash_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2027-04-01",
        "group_id" => "group-81",
        "amount_cents" => 100
      },
      overrides
    )
  end

  defp credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "credit-1",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-04-02",
        "group_id" => "group-81",
        "amount_cents" => 100
      },
      overrides
    )
  end

  defp reschedule_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "move-1",
        "type" => "reschedule_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "group-81",
        "new_arrival_on" => "2027-04-30"
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2027-04-02",
        "group_id" => "group-81"
      },
      overrides
    )
  end
end
