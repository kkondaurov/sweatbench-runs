defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp get_report(query) do
    get(build_conn(), "/api/v1/finance/daily-report" <> query)
  end

  defp report(date) do
    conn = get_report("?date=#{date}")
    assert %{"data" => data} = json_response(conn, 200)
    data
  end

  defp get_ledger(query \\ "") do
    conn = get(build_conn(), "/api/v1/ledger" <> query)
    json_response(conn, 200)["data"]
  end

  # Two flexible rooms for three nights: deposits 9_000 and 10_500.
  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
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

  # One flexible room for two nights at 20_000: an 8_000 deposit.
  defp open_one_room_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 4_000
      },
      overrides
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 2_000
      },
      overrides
    )
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
  end

  defp cancel_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp chargeback_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  # Opens, funds, and refunds a flexible group into a hotel credit lot of
  # `cash_cents` + 10%, expiring on 2027-11-20.
  defp issue_credit(conn, guest_id, group_id, cash_cents) do
    operations = [
      open_op(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "guest_id" => guest_id
      }),
      payment_op(%{
        "operation_id" => "op-pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      cancel_op(%{
        "operation_id" => "op-cancel-#{group_id}",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      })
    ]

    conn = post_batch(conn, %{"operations" => operations})
    assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)
  end

  describe "start_finance_reporting" do
    test "the applied result contains exactly operation_id, status, and starts_on", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [start_op()]})
      assert %{"results" => [result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => "2026-10-01"
             }
    end

    test "the opening position includes operations already committed, even those occurring on or after starts_on",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"occurred_on" => "2026-10-04"}),
        start_op(%{"starts_on" => "2026-10-01"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      data = report("2026-10-01")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 5_000
               }
             ] = data["cash"]

      assert Enum.all?(Map.values(hd(data["cash"])["movements"]), &(&1 == 0))
    end

    test "within one batch, operations before the start contribute to the opening position and later ones post movements",
         %{conn: conn} do
      operations = [
        open_op(),
        payment_op(%{"occurred_on" => "2026-09-30"}),
        start_op(),
        payment_op(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-10-02",
          "amount_cents" => 3_000
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, %{"status" => "applied"}]} = json_response(conn, 200)

      day_one = report("2026-10-01")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 5_000
               }
             ] = day_one["cash"]

      assert Enum.all?(Map.values(hd(day_one["cash"])["movements"]), &(&1 == 0))

      day_two = report("2026-10-02")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 8_000,
                 "movements" => %{"received_cents" => 3_000}
               }
             ] = day_two["cash"]
    end

    test "a different start is rejected once reporting has started, while the original replays",
         %{
           conn: conn
         } do
      conn = post_batch(conn, %{"operations" => [start_op()]})
      assert %{"results" => [result]} = json_response(conn, 200)

      # a retry of the original returns the stored result
      conn = post_batch(build_conn(), %{"operations" => [start_op()]})
      assert %{"results" => [^result]} = json_response(conn, 200)

      # a different start operation is rejected
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            start_op(%{"operation_id" => "op-start-2", "starts_on" => "2026-11-01"})
          ]
        })

      assert %{"results" => [rejected]} = json_response(conn, 200)
      assert rejected["status"] == "rejected"
      assert rejected["code"] == "reporting_already_started"

      # even one with the same start date
      conn =
        post_batch(build_conn(), %{
          "operations" => [start_op(%{"operation_id" => "op-start-3"})]
        })

      assert %{"results" => [rejected]} = json_response(conn, 200)
      assert rejected["code"] == "reporting_already_started"

      # reusing the original identifier with a different payload conflicts
      conn =
        post_batch(build_conn(), %{
          "operations" => [start_op(%{"starts_on" => "2026-10-02"})]
        })

      assert %{"results" => [conflict]} = json_response(conn, 200)
      assert conflict["code"] == "operation_id_conflict"

      # and the report still starts on the original date
      assert report("2026-10-01")["date"] == "2026-10-01"
    end

    test "rejects an invalid or missing starts_on as invalid_reporting_date", %{conn: conn} do
      operations = [
        start_op(%{"operation_id" => "op-s1", "starts_on" => "2026-13-01"}),
        start_op(%{"operation_id" => "op-s2", "starts_on" => "10/01/2026"}),
        start_op(%{"operation_id" => "op-s3", "starts_on" => nil}),
        start_op(%{"operation_id" => "op-s4", "starts_on" => 20_261_001}),
        Map.delete(start_op(%{"operation_id" => "op-s5"}), "starts_on")
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)

      assert Enum.all?(results, &(&1["status"] == "rejected"))
      assert Enum.all?(results, &(&1["code"] == "invalid_reporting_date"))

      # none of them started reporting
      assert json_response(get_report("?date=2026-10-01"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end

    test "missing common operation fields stay invalid_operation", %{conn: conn} do
      operations = [
        start_op(%{"operation_id" => "op-s1"}) |> Map.delete("occurred_on"),
        start_op(%{"operation_id" => "op-s2"})
        |> Map.delete("operation_id")
        |> Map.put("operation_id", nil)
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [missing_date, missing_id]} = json_response(conn, 200)

      assert missing_date["code"] == "invalid_operation"
      assert missing_id["code"] == "invalid_operation"

      assert json_response(get_report("?date=2026-10-01"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}
    end
  end

  describe "reading one day" do
    test "a missing or invalid date is 422 invalid_reporting_date", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [start_op()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      for query <- ["", "?date=", "?date=not-a-date", "?date=2026-13-40", "?other=2026-10-01"] do
        assert json_response(get_report(query), 422) ==
                 %{"error" => %{"code" => "invalid_reporting_date"}}
      end
    end

    test "before reporting starts, or for a date before starts_on, the report is not available",
         %{conn: conn} do
      assert json_response(get_report("?date=2026-10-01"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}

      conn =
        post_batch(conn, %{
          "operations" => [start_op(%{"starts_on" => "2026-10-01"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert json_response(get_report("?date=2026-09-30"), 404) ==
               %{"error" => %{"code" => "report_not_available"}}

      assert json_response(get_report("?date=2026-10-01"), 200)
    end

    test "a successful report has the documented top-level, cash, and credit shapes", %{
      conn: conn
    } do
      operations = [start_op(), open_op(), payment_op()]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)

      data = report("2026-10-04")

      assert Map.keys(data) |> Enum.sort() == [
               "cash",
               "credit",
               "date",
               "late_adjustments",
               "status"
             ]

      assert data["date"] == "2026-10-04"
      assert data["status"] == "open"

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 5_000,
                 "movements" => movements
               }
             ] = data["cash"]

      assert movements == %{
               "received_cents" => 5_000,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert data["credit"] == %{
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

      # nothing was moved forward by a close
      assert data["late_adjustments"] == %{
               "cash" => [],
               "credit" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               }
             }
    end

    test "a property is omitted only when its opening, closing, and every movement are zero", %{
      conn: conn
    } do
      operations = [
        start_op(),
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        payment_op(),
        transfer_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # nothing moved on the start date itself
      assert report("2026-10-01")["cash"] == []

      # yyz-airport never held anything on the payment day: omitted
      assert [%{"property_id" => "ams-canal"}] = report("2026-10-04")["cash"]

      # the transfer moved cash to it on 2026-10-05
      assert [
               %{"property_id" => "ams-canal"},
               %{"property_id" => "yyz-airport"}
             ] = report("2026-10-05")["cash"]
    end

    test "reading reports in any order or repeatedly never changes them", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        payment_op(),
        transfer_op()
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      first = report("2026-10-04")
      _later = report("2026-10-05")
      _earlier = report("2026-10-01")

      assert report("2026-10-04") == first
      assert report("2026-10-04") == first

      # the ledger is untouched by report reads
      assert %{"cash_held_cents" => 5_000} = get_ledger()
    end
  end

  describe "cash movements" do
    test "refundable and non-refundable settlements report refunded and retained cash", %{
      conn: conn
    } do
      operations = [
        start_op(),
        open_op(),
        open_one_room_op("group-82"),
        payment_op(),
        payment_op(%{
          "operation_id" => "op-pay-82",
          "group_id" => "group-82",
          "amount_cents" => 8_000
        }),
        cancel_op(%{"occurred_on" => "2026-11-20"}),
        cancel_op(%{
          "operation_id" => "op-cancel-82",
          "group_id" => "group-82",
          "occurred_on" => "2026-12-08"
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, _, _, refundable, non_refundable]} =
               json_response(conn, 200)

      assert refundable["refunded_cents"] == 5_000
      assert non_refundable["retained_cents"] == 8_000

      day = report("2026-11-20")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{"refunded_cents" => 5_000, "retained_cents" => 0}
               }
             ] = day["cash"]

      day = report("2026-12-08")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "closing_held_cents" => 0,
                 "movements" => %{"refunded_cents" => 0, "retained_cents" => 8_000}
               }
             ] = day["cash"]
    end

    test "a hotel-credit settlement converts the cash and issues liability", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        payment_op(),
        cancel_op(%{"refund_method" => "hotel_credit"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, cancel]} = json_response(conn, 200)
      assert cancel["credit_issued_cents"] == 5_500

      day = report("2026-11-20")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 0,
                 "movements" => %{"converted_to_credit_cents" => 5_000}
               }
             ] = day["cash"]

      assert %{
               "opening_liability_cents" => 0,
               "closing_liability_cents" => 5_500,
               "movements" => %{"issued_cents" => 5_500}
             } = day["credit"]
    end

    test "transfers move only cash between properties and net to zero company-wide", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(),
        payment_op(%{"amount_cents" => 4_000}),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        start_op(%{"starts_on" => "2026-10-04"}),
        # draws the most recent funding first: 4_000 cash, then 2_000 credit
        transfer_op(%{"occurred_on" => "2026-10-05", "amount_cents" => 6_000})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, _, _, _, transfer]} = json_response(conn, 200)
      assert transfer["status"] == "applied"

      day = report("2026-10-05")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 4_000,
                 "closing_held_cents" => 0,
                 "movements" => %{
                   "transferred_out_cents" => 4_000,
                   "transferred_in_cents" => 0
                 }
               },
               %{
                 "property_id" => "yyz-airport",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 4_000,
                 "movements" => %{
                   "transferred_in_cents" => 4_000,
                   "transferred_out_cents" => 0
                 }
               }
             ] = day["cash"]

      # moved credit stays liability; no credit movement at all
      assert day["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert day["credit"]["opening_liability_cents"] == 11_000
      assert day["credit"]["closing_liability_cents"] == 11_000
    end

    test "a reduction follows the cash to the property where it is currently held", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        payment_op(),
        transfer_op(),
        start_op(%{"starts_on" => "2026-10-05"}),
        reduce_op(%{"occurred_on" => "2026-10-06", "amount_cents" => 3_000})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, _, reduce]} = json_response(conn, 200)
      assert reduce["status"] == "applied"

      # reverse allocation order: the moved 2_000 at yyz-airport first, then
      # 1_000 back at the payment's original property
      day = report("2026-10-06")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 3_000,
                 "closing_held_cents" => 2_000,
                 "movements" => %{"reduced_cents" => 1_000}
               },
               %{
                 "property_id" => "yyz-airport",
                 "opening_held_cents" => 2_000,
                 "closing_held_cents" => 0,
                 "movements" => %{"reduced_cents" => 2_000}
               }
             ] = day["cash"]
    end

    test "a chargeback of held cash reports charged_back where it is held", %{conn: conn} do
      operations = [
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        payment_op(),
        transfer_op(),
        start_op(%{"starts_on" => "2026-10-05"}),
        chargeback_op(%{"occurred_on" => "2026-10-06"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, _, chargeback]} = json_response(conn, 200)
      assert chargeback["charged_back_cents"] == 5_000

      day = report("2026-10-06")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "closing_held_cents" => 0,
                 "movements" => %{"charged_back_cents" => 3_000}
               },
               %{
                 "property_id" => "yyz-airport",
                 "closing_held_cents" => 0,
                 "movements" => %{"charged_back_cents" => 2_000}
               }
             ] = day["cash"]

      assert get_ledger()["cash_charged_back_cents"] == 5_000
    end

    test "a chargeback of settled cash reports negative refunded with positive charged_back", %{
      conn: conn
    } do
      operations = [
        open_op(),
        payment_op(),
        # refundable: the cash settles as a refund
        cancel_op(%{"occurred_on" => "2026-11-20"}),
        start_op(%{"starts_on" => "2026-11-21"}),
        chargeback_op(%{"occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, chargeback]} = json_response(conn, 200)
      assert chargeback["charged_back_cents"] == 5_000

      day = report("2026-11-22")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 0,
                 "movements" => movements
               }
             ] = day["cash"]

      assert movements["refunded_cents"] == -5_000
      assert movements["charged_back_cents"] == 5_000

      # the reclassification nets to zero held cash: opening and closing agree
      assert day["cash"] |> hd() |> Map.get("opening_held_cents") == 0
    end

    test "a chargeback of cash settled after a transfer reports at the settling property", %{
      conn: conn
    } do
      operations = [
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        payment_op(),
        transfer_op(),
        # the moved 2_000 settles as a refund at the destination property
        cancel_op(%{
          "operation_id" => "op-cancel-82",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-20"
        }),
        start_op(%{"starts_on" => "2026-11-21"}),
        chargeback_op(%{"occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, cancel, _, chargeback]} = json_response(conn, 200)
      assert cancel["refunded_cents"] == 2_000
      assert chargeback["charged_back_cents"] == 5_000

      day = report("2026-11-22")

      # the correction follows the cash: the held remainder charges back at
      # the payment's property, and the settled share reverses its refund at
      # yyz-airport, where it settled
      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 3_000,
                 "closing_held_cents" => 0,
                 "movements" => %{"charged_back_cents" => 3_000, "refunded_cents" => 0}
               },
               %{
                 "property_id" => "yyz-airport",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 0,
                 "movements" => %{"charged_back_cents" => 2_000, "refunded_cents" => -2_000}
               }
             ] = day["cash"]
    end

    test "cancelling selected rooms settles their cash like a full cancellation", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        payment_op(%{"amount_cents" => 10_500}),
        %{
          "operation_id" => "op-cancel-rooms",
          "type" => "cancel_rooms",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "room_ids" => ["room-a"]
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"
      assert cancel["refunded_cents"] == 9_000

      day = report("2026-11-20")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 10_500,
                 "closing_held_cents" => 1_500,
                 "movements" => %{"refunded_cents" => 9_000}
               }
             ] = day["cash"]
    end
  end

  describe "credit movements" do
    test "applying and restoring credit leave liability unchanged and post no movement", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        start_op(%{"starts_on" => "2026-11-21"}),
        open_op(),
        credit_op(%{"occurred_on" => "2026-11-25"}),
        cancel_op(%{"occurred_on" => "2026-11-26"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, applied, cancel]} = json_response(conn, 200)
      assert applied["status"] == "applied"
      assert cancel["status"] == "applied"

      for date <- ["2026-11-25", "2026-11-26"] do
        day = report(date)

        assert day["credit"] == %{
                 "opening_liability_cents" => 11_000,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 11_000
               }

        # the group never held cash: no cash row appears for it
        assert day["cash"] == []
      end
    end

    test "a non-refundable settlement consumes the applied credit", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(%{"occurred_on" => "2026-11-25"}),
        start_op(%{"starts_on" => "2026-11-26"}),
        cancel_op(%{"occurred_on" => "2026-12-09"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"

      day = report("2026-12-09")

      assert %{
               "opening_liability_cents" => 11_000,
               "closing_liability_cents" => 7_000,
               "movements" => %{"consumed_cents" => 4_000}
             } = day["credit"]
    end

    test "a chargeback revokes the issued entitlement", %{conn: conn} do
      operations = [
        open_op(),
        payment_op(),
        cancel_op(%{"refund_method" => "hotel_credit"}),
        start_op(%{"starts_on" => "2026-11-21"}),
        chargeback_op(%{"occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, _, _, chargeback]} = json_response(conn, 200)
      assert chargeback["charged_back_cents"] == 5_000

      day = report("2026-11-22")

      assert %{
               "opening_liability_cents" => 5_500,
               "closing_liability_cents" => 0,
               "movements" => %{"revoked_cents" => 5_500}
             } = day["credit"]

      # the settled conversion reverses too
      assert [
               %{
                 "movements" => %{
                   "converted_to_credit_cents" => -5_000,
                   "charged_back_cents" => 5_000
                 }
               }
             ] = day["cash"]
    end

    test "restored credit absorbed by shortfall posts absorbed", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(%{"amount_cents" => 5_500, "occurred_on" => "2026-11-24"}),
        # revokes the lot's entitlement: 5_500 from the remainder and 5_500 of
        # unrecovered clawback against the applied credit
        chargeback_op(%{
          "operation_id" => "op-chargeback-91",
          "payment_operation_id" => "op-pay-group-91",
          "occurred_on" => "2026-11-25"
        }),
        start_op(%{"starts_on" => "2026-11-27"}),
        # refundable restore: the returning 5_500 is fully absorbed
        cancel_op(%{"occurred_on" => "2026-11-26"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"

      day = report("2026-11-27")

      assert %{
               "opening_liability_cents" => 5_500,
               "closing_liability_cents" => 0,
               "movements" => %{
                 "absorbed_cents" => 5_500,
                 "issued_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0
               }
             } = day["credit"]

      assert %{"credit_liability_cents" => 0} = get_ledger("?on=2026-11-27")
    end

    test "credit that remains unused through expires_on expires on the following date", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      conn =
        post_batch(build_conn(), %{
          "operations" => [start_op(%{"starts_on" => "2026-11-21"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # the lot expires on 2027-11-20; no partner operation happens that day
      day = report("2027-11-20")

      assert %{
               "opening_liability_cents" => 11_000,
               "closing_liability_cents" => 11_000,
               "movements" => %{"expired_cents" => 0}
             } = day["credit"]

      day = report("2027-11-21")

      assert %{
               "opening_liability_cents" => 11_000,
               "closing_liability_cents" => 0,
               "movements" => %{"expired_cents" => 11_000}
             } = day["credit"]

      # a later date keeps the expiry behind it
      day = report("2027-11-22")

      assert %{
               "opening_liability_cents" => 0,
               "closing_liability_cents" => 0,
               "movements" => %{"expired_cents" => 0}
             } = day["credit"]

      assert %{"credit_liability_cents" => 0} = get_ledger("?on=2027-11-21")
    end

    test "only the unused remainder expires; applied credit stays in liability", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        open_op(),
        credit_op(%{"occurred_on" => "2026-11-25"}),
        start_op(%{"starts_on" => "2026-11-26"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _, _]} = json_response(conn, 200)

      day = report("2027-11-21")

      assert %{
               "opening_liability_cents" => 11_000,
               "closing_liability_cents" => 4_000,
               "movements" => %{"expired_cents" => 7_000}
             } = day["credit"]

      assert %{"credit_liability_cents" => 4_000} = get_ledger("?on=2027-11-21")
    end

    test "a revocation after the lot expired moves no liability and keeps the frozen expiry", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      conn =
        post_batch(build_conn(), %{
          "operations" => [start_op(%{"starts_on" => "2026-11-21"})]
        })

      assert %{"results" => [_]} = json_response(conn, 200)

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            chargeback_op(%{
              "operation_id" => "op-chargeback-91",
              "payment_operation_id" => "op-pay-group-91",
              "occurred_on" => "2027-11-25"
            })
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # the lot already expired on 2027-11-21 with its full remainder
      assert %{"movements" => %{"expired_cents" => 11_000}} = report("2027-11-21")["credit"]

      # the revocation day itself shows no credit movement at all
      day = report("2027-11-25")

      assert day["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert day["credit"]["opening_liability_cents"] == 0
      assert day["credit"]["closing_liability_cents"] == 0

      assert %{"credit_liability_cents" => 0} = get_ledger("?on=2027-11-25")
    end

    test "credit restored after its lot expired expires on the spot", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      # the group arrives far in the future, so cancelling it stays
      # refundable even after the lot's 2027-11-20 expiry
      operations = [
        open_op(%{"arrival_on" => "2028-01-10", "departure_on" => "2028-01-13"}),
        credit_op(%{"occurred_on" => "2026-11-25"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => [_, _]} = json_response(conn, 200)

      conn =
        post_batch(build_conn(), %{
          "operations" => [start_op(%{"starts_on" => "2026-11-26"})]
        })

      assert %{"results" => [_]} = json_response(conn, 200)

      # the group is cancelled after the lot's 2027-11-20 expiry; the
      # refundable restore comes back and immediately expires
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            %{
              "operation_id" => "op-late-cancel",
              "type" => "cancel_group",
              "occurred_on" => "2027-12-01",
              "group_id" => "group-81"
            }
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      day = report("2027-12-01")

      # the applied 4_000 returns to an expired lot and leaves liability the
      # same day; the unused 7_000 remainder had already expired on 2027-11-21
      assert %{
               "opening_liability_cents" => 4_000,
               "closing_liability_cents" => 0,
               "movements" => %{"expired_cents" => 4_000}
             } = day["credit"]

      boundary = report("2027-11-21")
      assert %{"movements" => %{"expired_cents" => 7_000}} = boundary["credit"]

      assert %{"credit_liability_cents" => 0} = get_ledger("?on=2027-12-01")
    end
  end

  describe "posting dates and durability" do
    test "an operation occurring before starts_on posts at starts_on", %{conn: conn} do
      conn =
        post_batch(conn, %{"operations" => [start_op(%{"starts_on" => "2026-10-01"})]})

      assert %{"results" => [_]} = json_response(conn, 200)

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            open_op(%{"occurred_on" => "2026-09-15"}),
            payment_op(%{"occurred_on" => "2026-09-15"})
          ]
        })

      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      day = report("2026-10-01")

      assert [
               %{
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 5_000,
                 "movements" => %{"received_cents" => 5_000}
               }
             ] = day["cash"]
    end

    test "a later submission changes an earlier open report", %{conn: conn} do
      conn =
        post_batch(conn, %{"operations" => [start_op(%{"starts_on" => "2026-10-01"}), open_op()]})

      assert %{"results" => [_, _]} = json_response(conn, 200)

      before_payment = report("2026-10-04")
      assert before_payment["cash"] == []

      conn =
        post_batch(build_conn(), %{
          "operations" => [payment_op(%{"occurred_on" => "2026-10-04"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      after_payment = report("2026-10-04")

      assert [
               %{
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 5_000,
                 "movements" => %{"received_cents" => 5_000}
               }
             ] = after_payment["cash"]
    end

    test "rejected operations leave no reporting movement and the batch continues", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        # exceeds the outstanding deposit
        payment_op(%{"operation_id" => "op-pay-big", "amount_cents" => 19_501}),
        # invalid amount
        payment_op(%{"operation_id" => "op-pay-zero", "amount_cents" => 0}),
        payment_op(%{"operation_id" => "op-pay-good"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, over, zero, good]} = json_response(conn, 200)
      assert over["code"] == "payment_exceeds_outstanding"
      assert zero["code"] == "invalid_amount"
      assert good["status"] == "applied"

      day = report("2026-10-04")

      assert [
               %{
                 "closing_held_cents" => 5_000,
                 "movements" => %{"received_cents" => 5_000}
               }
             ] = day["cash"]
    end

    test "a durable retry returns the stored result and never reports a movement twice", %{
      conn: conn
    } do
      operations = [start_op(), open_op(), payment_op()]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, payment]} = json_response(conn, 200)

      conn = post_batch(build_conn(), %{"operations" => [payment_op()]})
      assert %{"results" => [^payment]} = json_response(conn, 200)

      assert [
               %{
                 "closing_held_cents" => 5_000,
                 "movements" => %{"received_cents" => 5_000}
               }
             ] = report("2026-10-04")["cash"]

      assert %{"cash_held_cents" => 5_000} = get_ledger()
    end

    test "equivalent batches and sequential submissions produce equivalent reports", %{conn: conn} do
      # the same history for two properties: one submitted as a single batch,
      # the other operation by operation
      batched_ops = [
        start_op(),
        open_op(%{"operation_id" => "op-a-open", "group_id" => "g-a", "property_id" => "prp-a"}),
        payment_op(%{"operation_id" => "op-a-pay", "group_id" => "g-a"}),
        cancel_op(%{"operation_id" => "op-a-cancel", "group_id" => "g-a"})
      ]

      conn = post_batch(conn, %{"operations" => batched_ops})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      sequential_ops = [
        open_op(%{"operation_id" => "op-b-open", "group_id" => "g-b", "property_id" => "prp-b"}),
        payment_op(%{"operation_id" => "op-b-pay", "group_id" => "g-b"}),
        cancel_op(%{"operation_id" => "op-b-cancel", "group_id" => "g-b"})
      ]

      Enum.each(sequential_ops, fn op ->
        conn = post_batch(build_conn(), %{"operations" => [op]})
        assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
      end)

      day = report("2026-11-20")

      assert [
               %{"property_id" => "prp-a"} = batched_row,
               %{"property_id" => "prp-b"} = sequential_row
             ] = day["cash"]

      assert Map.delete(batched_row, "property_id") == Map.delete(sequential_row, "property_id")
    end
  end

  describe "reconciliation" do
    test "closing balances reconcile with the current views", %{conn: conn} do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      operations = [
        start_op(%{"starts_on" => "2026-11-21"}),
        open_op(),
        credit_op(%{"occurred_on" => "2026-11-25"}),
        payment_op(%{"occurred_on" => "2026-11-25"}),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        transfer_op(%{"occurred_on" => "2026-11-26"}),
        cancel_op(%{"occurred_on" => "2026-11-28"})
      ]

      conn = post_batch(build_conn(), %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # the last report covers every posting date
      day = report("2026-11-28")

      closing_held =
        day["cash"]
        |> Enum.map(& &1["closing_held_cents"])
        |> Enum.sum()

      assert closing_held == get_ledger()["cash_held_cents"]

      assert day["credit"]["closing_liability_cents"] ==
               get_ledger("?on=2026-11-28")["credit_liability_cents"]

      # transferred-in equals transferred-out on every day
      for date <- ["2026-11-25", "2026-11-26", "2026-11-28"] do
        movements = Enum.map(report(date)["cash"], & &1["movements"])

        assert Enum.sum(Enum.map(movements, & &1["transferred_in_cents"])) ==
                 Enum.sum(Enum.map(movements, & &1["transferred_out_cents"]))
      end
    end
  end
end
