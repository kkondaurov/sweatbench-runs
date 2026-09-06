defmodule GroupStayWeb.Controllers.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: true

  @starts_on "2026-06-01"

  describe "close_finance_period operation" do
    test "applies with exactly operation_id, status, and period_end_on", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), start_operation(), close_operation()])

      assert %{"results" => [_, _, close]} = json_response(conn, 200)

      assert close == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-06-05"
             }
    end

    test "rejects a close before reporting has started", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), close_operation()])

      assert %{"results" => [_, close]} = json_response(conn, 200)

      assert close == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=2026-06-05"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "rejects a period_end_on before starts_on", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          start_operation(),
          close_operation(%{"period_end_on" => "2026-05-31"})
        ])

      assert %{"results" => [_, _, close]} = json_response(conn, 200)
      assert close["code"] == "invalid_period"
    end

    test "rejects an invalid or missing period_end_on", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          start_operation(),
          close_operation(%{"period_end_on" => nil}),
          close_operation(%{"operation_id" => "op-close-2", "period_end_on" => "junk"}),
          close_operation(%{"operation_id" => "op-close-3", "period_end_on" => "2026-06-31"})
        ])

      assert %{"results" => [_, _, first, second, third]} = json_response(conn, 200)
      assert first["code"] == "invalid_period"
      assert second["code"] == "invalid_period"
      assert third["code"] == "invalid_period"
    end

    test "rejects the same or an earlier cutoff from a different operation and applies a later one",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          start_operation(),
          close_operation(),
          close_operation(%{"operation_id" => "op-close-same"}),
          close_operation(%{
            "operation_id" => "op-close-earlier",
            "period_end_on" => "2026-06-04"
          }),
          close_operation(%{"operation_id" => "op-close-later", "period_end_on" => "2026-06-06"})
        ])

      assert %{"results" => [_, _, first, same, earlier, later]} = json_response(conn, 200)
      assert first["status"] == "applied"

      assert same == %{
               "operation_id" => "op-close-same",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert earlier == %{
               "operation_id" => "op-close-earlier",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      assert later == %{
               "operation_id" => "op-close-later",
               "status" => "applied",
               "period_end_on" => "2026-06-06"
             }
    end

    test "replaying an applied close returns its exact stored result", %{conn: conn} do
      conn =
        post_operations(conn, [open_group_operation(), start_operation(), close_operation()])

      assert %{"results" => [_, _, first]} = json_response(conn, 200)

      conn = post_operations(conn, [close_operation()])
      assert %{"results" => [second]} = json_response(conn, 200)
      assert second == first

      conn = post_operations(conn, [close_operation(%{"period_end_on" => "2026-06-06"})])
      assert %{"results" => [conflict]} = json_response(conn, 200)

      assert conflict == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      # The conflicting retry left the original close in place.
      assert report(conn, "2026-06-05")["status"] == "closed"
      assert report(conn, "2026-06-06")["status"] == "open"
    end

    test "a retry of a rejected close returns the original rejection", %{conn: conn} do
      conn = post_operations(conn, [close_operation()])
      assert %{"results" => [rejected]} = json_response(conn, 200)
      assert rejected["status"] == "rejected"

      conn = post_operations(conn, [close_operation()])
      assert %{"results" => [retried]} = json_response(conn, 200)
      assert retried == rejected
    end

    test "the stored close result is readable through the operations endpoint", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), start_operation(), close_operation()])

      assert %{"results" => [_, _, close]} = json_response(conn, 200)
      assert %{"data" => stored} = json_response(get(conn, "/api/v1/operations/op-close"), 200)
      assert stored == close
    end
  end

  describe "closed and open reports" do
    test "reports through the cutoff return closed and later reports open", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(),
          start_operation(),
          close_operation()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-01")["status"] == "closed"
      assert report(conn, "2026-06-03")["status"] == "closed"
      assert report(conn, "2026-06-05")["status"] == "closed"
      assert report(conn, "2026-06-06")["status"] == "open"
    end

    test "closed reports stay byte-for-byte stable across later operations and later closes", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"occurred_on" => "2026-06-02"}),
          start_operation()
        ])

      conn =
        post_operations(conn, [
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "occurred_on" => "2026-06-03",
            "amount_cents" => 3_000
          })
        ])

      conn = post_operations(conn, [close_operation()])

      # The close publishes every report through its cutoff.
      published = Enum.map(~w(2026-06-02 2026-06-03 2026-06-04 2026-06-05), &report(conn, &1))
      assert Enum.all?(published, &(&1["status"] == "closed"))

      conn =
        post_operations(conn, [
          payment_operation(%{
            "operation_id" => "op-pay-3",
            "occurred_on" => "2026-06-04",
            "amount_cents" => 1_000
          }),
          close_operation(%{"operation_id" => "op-close-2", "period_end_on" => "2026-06-08"})
        ])

      assert %{"results" => [_, second_close]} = json_response(conn, 200)
      assert second_close["status"] == "applied"

      # Every published report is unchanged, including the day the late
      # payment's occurred_on names.
      assert Enum.map(~w(2026-06-02 2026-06-03 2026-06-04 2026-06-05), &report(conn, &1)) ==
               published

      # The late payment posted on the first open day and is now closed too.
      late_day = report(conn, "2026-06-06")

      assert late_day == %{
               "date" => "2026-06-06",
               "status" => "closed",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 8_000,
                   "movements" => zero_movements(),
                   "closing_held_cents" => 9_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{zero_movements() | "received_cents" => 1_000}
                   }
                 ],
                 "credit" => zero_credit_movements()
               }
             }

      assert report(conn, "2026-06-09")["status"] == "open"
      assert %{"cash_held_cents" => 9_000} = ledger(conn)
    end
  end

  describe "posting after a close" do
    test "an operation immediately before a close can post into the period being closed", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_group_operation(),
          start_operation(),
          payment_operation(%{"occurred_on" => "2026-06-04", "amount_cents" => 3_000}),
          close_operation()
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert report(conn, "2026-06-04") == %{
               "date" => "2026-06-04",
               "status" => "closed",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{zero_movements() | "received_cents" => 3_000},
                   "closing_held_cents" => 3_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => zero_credit_movements()
               }
             }
    end

    test "an old-dated operation immediately after a close posts on the first open day", %{
      conn: conn
    } do
      conn = post_operations(conn, [open_group_operation(), start_operation(), close_operation()])

      conn =
        post_operations(conn, [
          payment_operation(%{"occurred_on" => "2026-06-03", "amount_cents" => 3_000})
        ])

      # The closed day stays untouched.
      assert report(conn, "2026-06-03")["cash"] == []

      assert report(conn, "2026-06-06") == %{
               "date" => "2026-06-06",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => zero_movements(),
                   "closing_held_cents" => 3_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "cash" => [
                   %{
                     "property_id" => "ams-canal",
                     "movements" => %{zero_movements() | "received_cents" => 3_000}
                   }
                 ],
                 "credit" => zero_credit_movements()
               }
             }
    end

    test "an operation occurring on the first open day posts there, not late", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), start_operation(), close_operation()])

      conn =
        post_operations(conn, [
          payment_operation(%{"occurred_on" => "2026-06-06", "amount_cents" => 3_000})
        ])

      day = report(conn, "2026-06-06")

      assert List.first(day["cash"])["movements"]["received_cents"] == 3_000
      assert day["late_adjustments"] == %{"cash" => [], "credit" => zero_credit_movements()}
    end

    test "an operation keeps the posting date chosen when it commits", %{conn: conn} do
      conn = post_operations(conn, [open_group_operation(), start_operation(), close_operation()])

      conn =
        post_operations(conn, [
          payment_operation(%{"occurred_on" => "2026-06-03", "amount_cents" => 3_000})
        ])

      before_second_close = report(conn, "2026-06-06")

      conn =
        post_operations(conn, [
          close_operation(%{"operation_id" => "op-close-2", "period_end_on" => "2026-06-10"})
        ])

      assert %{"results" => [close]} = json_response(conn, 200)
      assert close["status"] == "applied"

      # The second close published the day but did not move the posting.
      assert report(conn, "2026-06-06") == %{before_second_close | "status" => "closed"}

      # An even older operation after the second close posts after its cutoff.
      conn =
        post_operations(conn, [
          payment_operation(%{"operation_id" => "op-pay-2", "occurred_on" => "2026-06-02"})
        ])

      day = report(conn, "2026-06-11")

      assert List.first(day["cash"])["closing_held_cents"] == 8_000
      assert List.first(day["late_adjustments"]["cash"])["movements"]["received_cents"] == 5_000
    end
  end

  describe "late adjustments" do
    test "the late cash array is ordered by property and omits all-zero properties", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          start_operation(),
          close_operation()
        ])

      conn =
        post_operations(conn, [
          payment_operation(%{"occurred_on" => "2026-06-02", "amount_cents" => 3_000}),
          payment_operation(%{
            "operation_id" => "op-pay-92",
            "group_id" => "group-92",
            "occurred_on" => "2026-06-04",
            "amount_cents" => 2_000
          })
        ])

      day = report(conn, "2026-06-06")

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_movements() | "received_cents" => 3_000}
               },
               %{
                 "property_id" => "bru-grand",
                 "movements" => %{zero_movements() | "received_cents" => 2_000}
               }
             ]

      assert Enum.map(day["cash"], & &1["property_id"]) == ["ams-canal", "bru-grand"]
      assert day["status"] == "open"
    end

    test "signed classifications survive a net-zero late adjustment", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(),
          start_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-02"}),
          close_operation(),
          charge_back_operation(%{"occurred_on" => "2026-06-03"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The refund settled inside the closed period; the chargeback posts after
      # it, on the first open day, reversing the refund where it was settled.
      day = report(conn, "2026-06-06")

      assert day["cash"] == []

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{
                   zero_movements()
                   | "refunded_cents" => -5_000,
                     "charged_back_cents" => 5_000
                 }
               }
             ]

      assert %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 5_000} = ledger(conn)
    end

    test "a late hotel-credit conversion reports late cash and credit movements", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"occurred_on" => "2026-06-02", "amount_cents" => 8_000}),
          start_operation(),
          close_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-03", "refund_method" => "hotel_credit"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      day = report(conn, "2026-06-06")

      assert day["status"] == "open"

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_movements() | "converted_to_credit_cents" => 8_000}
               }
             ]

      assert day["late_adjustments"]["credit"] == %{
               zero_credit_movements()
               | "issued_cents" => 8_800
             }

      assert List.first(day["cash"])["closing_held_cents"] == 0
      assert day["credit"]["closing_liability_cents"] == 8_800

      assert %{"credit_liability_cents" => 8_800} = ledger(conn)
    end

    test "a late chargeback of held cash follows the property where it is held", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"occurred_on" => "2026-06-02"}),
          start_operation(),
          close_operation(),
          charge_back_operation(%{"occurred_on" => "2026-06-03"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      day = report(conn, "2026-06-06")

      assert day["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => zero_movements(),
                 "closing_held_cents" => 0
               }
             ]

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_movements() | "charged_back_cents" => 5_000}
               }
             ]

      assert %{"cash_held_cents" => 0, "cash_charged_back_cents" => 5_000} = ledger(conn)
    end

    test "a late chargeback revokes the credit entitlement as a late adjustment", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"occurred_on" => "2026-06-02", "amount_cents" => 8_000}),
          start_operation(),
          close_operation(),
          cancel_operation(%{"occurred_on" => "2026-06-03", "refund_method" => "hotel_credit"}),
          charge_back_operation(%{"occurred_on" => "2026-06-04"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The conversion and the chargeback both post on the first open day, in
      # commit order: the lot is issued and its entitlement revoked at once.
      day = report(conn, "2026-06-06")

      assert day["late_adjustments"]["credit"] == %{
               zero_credit_movements()
               | "issued_cents" => 8_800,
                 "revoked_cents" => 8_800
             }

      assert day["credit"]["closing_liability_cents"] == 0

      late_cash = List.first(day["late_adjustments"]["cash"])
      assert late_cash["movements"]["charged_back_cents"] == 8_000
      assert List.first(day["cash"])["closing_held_cents"] == 0

      assert %{"credit_liability_cents" => 0} = ledger(conn)
    end

    test "report movements reconcile with the ledger across closes", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          open_destination_operation(),
          payment_operation(),
          start_operation(),
          close_operation(%{"period_end_on" => "2026-06-03"}),
          transfer_operation(%{"occurred_on" => "2026-06-05"}),
          payment_operation(%{
            "operation_id" => "op-pay-2",
            "occurred_on" => "2026-06-02",
            "amount_cents" => 3_000
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # The transfer committed before the payment: it posts inside the open
      # period after the first close; the payment posts on the day after the
      # latest cutoff, as a late adjustment.
      transfer_day = report(conn, "2026-06-05")

      assert Enum.map(transfer_day["cash"], & &1["property_id"]) == ["ams-canal", "bru-grand"]

      assert Enum.reduce(
               transfer_day["cash"],
               0,
               &(&1["movements"]["transferred_out_cents"] + &2)
             ) ==
               3_000

      payment_day = report(conn, "2026-06-04")

      assert payment_day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_movements() | "received_cents" => 3_000}
               }
             ]

      assert %{"cash_held_cents" => held} = ledger(conn)

      assert Enum.reduce(payment_day["cash"], 0, &(&1["closing_held_cents"] + &2)) == held
    end
  end

  defp start_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "rep-start",
        "type" => "start_finance_reporting",
        "occurred_on" => @starts_on,
        "starts_on" => @starts_on
      },
      overrides
    )
  end

  defp close_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-close",
        "type" => "close_finance_period",
        "occurred_on" => "2026-06-05",
        "period_end_on" => "2026-06-05"
      },
      overrides
    )
  end

  defp open_destination_operation(overrides \\ %{}) do
    open_group_operation(
      Map.merge(
        %{
          "operation_id" => "op-open-92",
          "group_id" => "group-92",
          "property_id" => "bru-grand",
          "rooms" => [
            %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
            %{"room_id" => "room-d", "nightly_rate_cents" => 8_333}
          ]
        },
        overrides
      )
    )
  end

  defp payment_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-05-20",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-06-02",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp transfer_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-06-02",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 3_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cb",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-06-05",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp report(conn, date) do
    assert %{"data" => data} =
             json_response(get(conn, "/api/v1/finance/daily-report?date=#{date}"), 200)

    data
  end

  defp ledger(conn) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)
    data
  end

  defp zero_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end
end
