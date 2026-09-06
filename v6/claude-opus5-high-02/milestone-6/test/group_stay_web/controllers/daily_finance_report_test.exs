defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  @no_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @no_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  describe "starting finance reporting" do
    test "the applied result contains exactly the operation, its status, and the start date" do
      result = submit_one(start_finance_reporting(%{"starts_on" => "2026-10-05"}))

      assert result == %{
               "operation_id" => "op-start-reporting",
               "status" => "applied",
               "starts_on" => "2026-10-05"
             }
    end

    test "a later start operation is rejected once reporting has started" do
      submit_one(start_finance_reporting())

      assert %{"status" => "rejected", "code" => "reporting_already_started"} =
               submit_one(
                 start_finance_reporting(%{
                   "operation_id" => "op-start-again",
                   "starts_on" => "2026-11-01"
                 })
               )
    end

    test "the first start operation still stands after a second one is rejected" do
      submit([
        start_finance_reporting(%{"starts_on" => "2026-10-01"}),
        start_finance_reporting(%{"operation_id" => "op-again", "starts_on" => "2026-11-01"})
      ])

      assert {200, _report} = read_daily_report("2026-10-01")
    end

    test "an unusable start date is rejected" do
      for starts_on <- ["", "not-a-date", "2026-13-01", 20_261_001, nil] do
        assert %{"status" => "rejected", "code" => "invalid_reporting_date"} =
                 submit_one(
                   start_finance_reporting(%{
                     "operation_id" => "op-start-#{inspect(starts_on)}",
                     "starts_on" => starts_on
                   })
                 )
      end
    end

    test "a missing start date is rejected" do
      operation = Map.delete(start_finance_reporting(), "starts_on")

      assert %{"status" => "rejected", "code" => "invalid_reporting_date"} = submit_one(operation)
    end

    test "an unusable date is rejected as already started once reporting has started" do
      submit_one(start_finance_reporting())

      assert %{"status" => "rejected", "code" => "reporting_already_started"} =
               submit_one(
                 start_finance_reporting(%{"operation_id" => "op-again", "starts_on" => "nope"})
               )
    end

    test "a rejected start operation does not enable reporting" do
      submit_one(start_finance_reporting(%{"starts_on" => "nope"}))

      assert {404, %{"error" => %{"code" => "report_not_available"}}} =
               read_daily_report("2026-10-01")
    end

    test "a retry returns the stored result and does not restart reporting" do
      first = submit_one(start_finance_reporting())

      assert submit_one(start_finance_reporting()) == first
      assert {200, %{"data" => stored}} = read_operation("op-start-reporting")
      assert stored == first
    end

    test "reusing the identifier with a different start date conflicts" do
      submit_one(start_finance_reporting())

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} =
               submit_one(start_finance_reporting(%{"starts_on" => "2026-11-01"}))
    end
  end

  describe "reading a day" do
    test "a report is unavailable before reporting has started" do
      assert {404, %{"error" => %{"code" => "report_not_available"}}} =
               read_daily_report("2026-10-01")
    end

    test "a date before the start date is unavailable" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-05"}))

      assert {404, %{"error" => %{"code" => "report_not_available"}}} =
               read_daily_report("2026-10-04")

      assert {200, _report} = read_daily_report("2026-10-05")
    end

    test "a missing or unusable date is rejected" do
      submit_one(start_finance_reporting())

      assert {422, %{"error" => %{"code" => "invalid_reporting_date"}}} =
               get_json("/api/v1/finance/daily-report")

      assert {422, %{"error" => %{"code" => "invalid_reporting_date"}}} =
               read_daily_report("2026-13-40")
    end

    test "an empty day reports itself with no properties and no credit movement" do
      submit_one(start_finance_reporting())

      assert daily_report("2026-10-01") == %{
               "date" => "2026-10-01",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => @no_credit_movements,
                 "closing_liability_cents" => 0
               }
             }
    end
  end

  describe "the opening position" do
    test "everything committed before the start operation opens the first day" do
      submit([open_group(), record_cash_payment(%{"amount_cents" => 4_000})])
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-10"}))

      assert property_cash("2026-10-10", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 4_000,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 4_000
             }
    end

    test "an earlier operation dated after the start date is still part of the opening" do
      submit([
        open_group(),
        record_cash_payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000})
      ])

      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-10"}))

      assert %{"opening_held_cents" => 4_000, "movements" => @no_cash_movements} =
               property_cash("2026-10-10", "ams-canal")

      assert property_cash("2026-10-20", "ams-canal")["movements"]["received_cents"] == 0
    end

    test "the opening position states what the ledger already holds" do
      submit([
        open_group(%{"rooms" => [room("room-a", 15_000), room("room-b", 17_500)]}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "par-rive",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-13"
        }),
        # Enough to fill room-a's 9000 deposit and leave 3000 held against room-b.
        record_cash_payment(%{"amount_cents" => 12_000}),
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-92",
          "amount_cents" => 2_000
        }),
        cancel_rooms(%{
          "occurred_on" => "2026-11-20",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        })
      ])

      submit_one(start_finance_reporting(%{"starts_on" => "2026-12-01"}))

      report = daily_report("2026-12-01")
      ledger = read_ledger(%{"on" => "2026-12-01"})

      assert Enum.sum(Enum.map(report["cash"], & &1["opening_held_cents"])) ==
               ledger["cash_held_cents"]

      assert report["credit"]["opening_liability_cents"] == ledger["credit_liability_cents"]
      assert report["credit"]["opening_liability_cents"] == 9_900

      assert Enum.map(report["cash"], &{&1["property_id"], &1["opening_held_cents"]}) ==
               [{"ams-canal", 3_000}, {"par-rive", 2_000}]

      assert_balanced(report)
    end

    test "credit issued before reporting started still expires on a reported day" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")
      submit_one(start_finance_reporting(%{"starts_on" => "2026-12-01"}))

      assert daily_report("2026-12-01")["credit"]["opening_liability_cents"] == 1_100

      assert daily_report("2027-11-27")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => %{@no_credit_movements | "expired_cents" => 1_100},
               "closing_liability_cents" => 0
             }

      assert read_ledger(%{"on" => "2027-11-27"})["credit_liability_cents"] == 0
    end

    test "within one batch the start splits the opening from the movements" do
      submit([
        open_group(),
        record_cash_payment(%{"operation_id" => "op-pay-1", "amount_cents" => 4_000}),
        start_finance_reporting(%{"starts_on" => "2026-10-04"}),
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 1_000
        })
      ])

      assert property_cash("2026-10-04", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 4_000,
               "movements" => %{@no_cash_movements | "received_cents" => 1_000},
               "closing_held_cents" => 5_000
             }
    end
  end

  describe "posting dates" do
    test "an operation posts on its own date" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      submit([open_group(), record_cash_payment(%{"occurred_on" => "2026-10-04"})])

      assert property_cash("2026-10-03", "ams-canal") == nil

      assert property_cash("2026-10-04", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{@no_cash_movements | "received_cents" => 1_000},
               "closing_held_cents" => 1_000
             }
    end

    test "an operation dated before the start posts on the start date" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-11-01"}))

      submit([
        open_group(),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 1_000})
      ])

      assert property_cash("2026-11-01", "ams-canal")["movements"]["received_cents"] == 1_000
    end

    test "a later submission changes an already open earlier day" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      submit([open_group(), record_cash_payment(%{"occurred_on" => "2026-10-04"})])

      assert property_cash("2026-10-02", "ams-canal") == nil

      submit_one(
        record_cash_payment(%{
          "operation_id" => "op-pay-back",
          "occurred_on" => "2026-10-02",
          "amount_cents" => 500
        })
      )

      assert property_cash("2026-10-02", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{@no_cash_movements | "received_cents" => 500},
               "closing_held_cents" => 500
             }

      assert property_cash("2026-10-04", "ams-canal")["opening_held_cents"] == 500
    end

    test "days chain: one day's closing balance opens the next" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      submit([open_group(), record_cash_payment(%{"occurred_on" => "2026-10-04"})])

      assert property_cash("2026-10-04", "ams-canal")["closing_held_cents"] == 1_000
      assert property_cash("2026-10-05", "ams-canal")["opening_held_cents"] == 1_000
      assert property_cash("2026-10-05", "ams-canal")["closing_held_cents"] == 1_000
    end
  end

  describe "cash movements" do
    setup do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      submit([open_group(), record_cash_payment(%{"amount_cents" => 2_000})])
      :ok
    end

    test "a refundable cancellation refunds the cash it held" do
      submit_one(cancel_group(%{"occurred_on" => "2026-11-20"}))

      assert property_cash("2026-11-20", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2_000,
               "movements" => %{@no_cash_movements | "refunded_cents" => 2_000},
               "closing_held_cents" => 0
             }
    end

    test "a non-refundable cancellation retains the cash it held" do
      submit_one(cancel_group(%{"occurred_on" => "2026-12-01"}))

      assert property_cash("2026-12-01", "ams-canal")["movements"] ==
               %{@no_cash_movements | "retained_cents" => 2_000}
    end

    test "converting cash to hotel credit moves it out of held cash and into liability" do
      submit_one(
        cancel_group(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      )

      report = daily_report("2026-11-20")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 2_000,
                 "movements" => %{@no_cash_movements | "converted_to_credit_cents" => 2_000},
                 "closing_held_cents" => 0
               }
             ]

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{@no_credit_movements | "issued_cents" => 2_200},
               "closing_liability_cents" => 2_200
             }
    end

    test "a reduction takes cash out of the held balance" do
      submit_one(reduce_cash_payment(%{"occurred_on" => "2026-10-09", "amount_cents" => 500}))

      assert property_cash("2026-10-09", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2_000,
               "movements" => %{@no_cash_movements | "reduced_cents" => 500},
               "closing_held_cents" => 1_500
             }
    end

    test "a chargeback of held cash takes it out of the held balance" do
      submit_one(charge_back_payment(%{"occurred_on" => "2026-10-09"}))

      assert property_cash("2026-10-09", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 2_000,
               "movements" => %{@no_cash_movements | "charged_back_cents" => 2_000},
               "closing_held_cents" => 0
             }
    end

    test "a chargeback of refunded cash reverses the refund it reported" do
      submit_one(cancel_group(%{"occurred_on" => "2026-11-20"}))
      submit_one(charge_back_payment(%{"occurred_on" => "2026-11-21"}))

      assert property_cash("2026-11-21", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 @no_cash_movements
                 | "refunded_cents" => -2_000,
                   "charged_back_cents" => 2_000
               },
               "closing_held_cents" => 0
             }
    end

    test "a chargeback of retained cash reverses the retention it reported" do
      submit_one(cancel_group(%{"occurred_on" => "2026-12-01"}))
      submit_one(charge_back_payment(%{"occurred_on" => "2026-12-02"}))

      assert property_cash("2026-12-02", "ams-canal")["movements"] ==
               %{@no_cash_movements | "retained_cents" => -2_000, "charged_back_cents" => 2_000}
    end
  end

  describe "properties" do
    test "properties are reported in identifier order and quiet ones are left out" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(%{
          "operation_id" => "op-open-b",
          "group_id" => "group-b",
          "property_id" => "par-rive"
        }),
        open_group(%{
          "operation_id" => "op-open-a",
          "group_id" => "group-a",
          "property_id" => "ams-canal"
        }),
        # A property whose group never receives cash has nothing to report.
        open_group(%{
          "operation_id" => "op-open-c",
          "group_id" => "group-c",
          "property_id" => "ber-mitte"
        }),
        record_cash_payment(%{
          "operation_id" => "op-pay-b",
          "group_id" => "group-b",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 700
        }),
        record_cash_payment(%{
          "operation_id" => "op-pay-a",
          "group_id" => "group-a",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 300
        })
      ])

      assert Enum.map(daily_report("2026-10-04")["cash"], & &1["property_id"]) ==
               ["ams-canal", "par-rive"]
    end

    test "a property is left out only when its balances and every movement are zero" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 1_000}),
        reduce_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 1_000})
      ])

      # The day opens and closes at nothing, but cash did move through it.
      assert property_cash("2026-10-04", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 0,
               "movements" => %{
                 @no_cash_movements
                 | "received_cents" => 1_000,
                   "reduced_cents" => 1_000
               },
               "closing_held_cents" => 0
             }

      assert daily_report("2026-10-05")["cash"] == []
    end
  end

  describe "transfers" do
    setup do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "par-rive"
        }),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 2_000})
      ])

      :ok
    end

    test "cash leaves the source property and arrives at the destination property" do
      submit_one(transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 800}))

      report = daily_report("2026-10-08")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 2_000,
                 "movements" => %{@no_cash_movements | "transferred_out_cents" => 800},
                 "closing_held_cents" => 1_200
               },
               %{
                 "property_id" => "par-rive",
                 "opening_held_cents" => 0,
                 "movements" => %{@no_cash_movements | "transferred_in_cents" => 800},
                 "closing_held_cents" => 800
               }
             ]
    end

    test "transferred in and transferred out are equal across the properties of a day" do
      submit_one(transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 800}))

      movements = Enum.map(daily_report("2026-10-08")["cash"], & &1["movements"])

      assert Enum.sum(Enum.map(movements, & &1["transferred_in_cents"])) ==
               Enum.sum(Enum.map(movements, & &1["transferred_out_cents"]))
    end

    test "a correction follows transferred cash to the property now holding it" do
      submit_one(transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 800}))

      submit_one(reduce_cash_payment(%{"occurred_on" => "2026-10-09", "amount_cents" => 800}))

      assert property_cash("2026-10-09", "par-rive") == %{
               "property_id" => "par-rive",
               "opening_held_cents" => 800,
               "movements" => %{@no_cash_movements | "reduced_cents" => 800},
               "closing_held_cents" => 0
             }

      # The property the payment was recorded at keeps what it still holds and reports no
      # reduction of its own.
      assert property_cash("2026-10-09", "ams-canal") == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 1_200,
               "movements" => @no_cash_movements,
               "closing_held_cents" => 1_200
             }
    end

    test "a settlement at the destination reports at the destination's property" do
      submit_one(transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 800}))

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-20"
        })
      )

      assert property_cash("2026-11-20", "par-rive")["movements"] ==
               %{@no_cash_movements | "refunded_cents" => 800}
    end
  end

  describe "corrections across properties" do
    setup do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "par-rive"
        }),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 2_000}),
        transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 800}),
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      ])

      :ok
    end

    test "a chargeback splits between where the cash is held and where it was settled" do
      submit_one(charge_back_payment(%{"occurred_on" => "2026-11-22"}))

      report = daily_report("2026-11-22")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 1_200,
                 "movements" => %{@no_cash_movements | "charged_back_cents" => 1_200},
                 "closing_held_cents" => 0
               },
               %{
                 "property_id" => "par-rive",
                 "opening_held_cents" => 0,
                 "movements" => %{
                   @no_cash_movements
                   | "charged_back_cents" => 800,
                     "converted_to_credit_cents" => -800
                 },
                 "closing_held_cents" => 0
               }
             ]

      assert_balanced(report)
    end

    test "the credit the settled cash bought is revoked with the chargeback" do
      submit_one(charge_back_payment(%{"occurred_on" => "2026-11-22"}))

      assert daily_report("2026-11-22")["credit"] == %{
               "opening_liability_cents" => 880,
               "movements" => %{@no_credit_movements | "revoked_cents" => 880},
               "closing_liability_cents" => 0
             }
    end
  end

  describe "credit movements" do
    setup do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      :ok
    end

    test "credit issued by a settlement enters the liability" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")

      assert daily_report("2026-11-26")["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{@no_credit_movements | "issued_cents" => 1_100},
               "closing_liability_cents" => 1_100
             }
    end

    test "credit left unused expires the day after its expiry date, with no operation that day" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")

      assert %{"expires_on" => "2027-11-26"} = hd(read_credit("guest-22")["lots"])

      assert daily_report("2027-11-26")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 1_100
             }

      assert daily_report("2027-11-27")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => %{@no_credit_movements | "expired_cents" => 1_100},
               "closing_liability_cents" => 0
             }

      assert read_ledger(%{"on" => "2027-11-27"})["credit_liability_cents"] == 0
    end

    test "applying credit is not a movement of the liability or of held cash" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")
      open_funded_group("group-b")

      submit_one(
        apply_hotel_credit(%{
          "operation_id" => "op-credit-b",
          "group_id" => "group-b",
          "occurred_on" => "2026-12-01",
          "amount_cents" => 1_100
        })
      )

      report = daily_report("2026-12-01")

      assert report["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 1_100
             }

      assert report["cash"] == []
    end

    test "credit kept by a non-refundable settlement is consumed" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")
      open_funded_group("group-b")
      apply_credit("group-b", 1_100, "2026-12-01")

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2027-12-01"
        })
      )

      assert daily_report("2027-12-01")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => %{@no_credit_movements | "consumed_cents" => 1_100},
               "closing_liability_cents" => 0
             }
    end

    test "a chargeback revokes the entitlement its cash bought" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")

      submit_one(
        charge_back_payment(%{
          "occurred_on" => "2026-12-01",
          "payment_operation_id" => "op-pay-group-a"
        })
      )

      report = daily_report("2026-12-01")

      assert report["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => %{@no_credit_movements | "revoked_cents" => 1_100},
               "closing_liability_cents" => 0
             }

      assert hd(report["cash"])["movements"] == %{
               @no_cash_movements
               | "charged_back_cents" => 1_000,
                 "converted_to_credit_cents" => -1_000
             }
    end

    test "credit returning to a lot a chargeback left short is absorbed" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")
      open_funded_group("group-b")
      apply_credit("group-b", 1_100, "2026-12-01")

      submit_one(
        charge_back_payment(%{
          "occurred_on" => "2026-12-02",
          "payment_operation_id" => "op-pay-group-a"
        })
      )

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2026-12-03"
        })
      )

      # The lot could give nothing back, so nothing was revoked from the liability that day.
      assert daily_report("2026-12-02")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 1_100
             }

      assert daily_report("2026-12-03")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => %{@no_credit_movements | "absorbed_cents" => 1_100},
               "closing_liability_cents" => 0
             }

      assert read_ledger(%{"on" => "2026-12-03"})["credit_liability_cents"] == 0
    end

    test "credit restored after its lot expired leaves the liability as expiry" do
      issue_credit(group_id: "group-a", cash_cents: 1_000, operation_id: "op-cancel-a")
      open_funded_group("group-b", "2028-06-10")
      apply_credit("group-b", 1_100, "2026-12-01")

      # The lot expires on 2027-11-26 while its credit is applied, so nothing expires with it.
      assert daily_report("2027-11-27")["credit"]["movements"] == @no_credit_movements

      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2028-01-05"
        })
      )

      assert daily_report("2028-01-05")["credit"] == %{
               "opening_liability_cents" => 1_100,
               "movements" => %{@no_credit_movements | "expired_cents" => 1_100},
               "closing_liability_cents" => 0
             }
    end
  end

  describe "reconciling with the current views" do
    test "closing balances agree with the ledger after a long history" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(%{"rooms" => [room("room-a", 15_000), room("room-b", 17_500)]}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "par-rive",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-13"
        }),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 5_000}),
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 2_000
        }),
        transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 1_500}),
        reduce_cash_payment(%{"occurred_on" => "2026-10-09", "amount_cents" => 500}),
        cancel_rooms(%{
          "occurred_on" => "2026-11-20",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        }),
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-21"
        }),
        charge_back_payment(%{
          "operation_id" => "op-chargeback-2",
          "occurred_on" => "2026-11-22",
          "payment_operation_id" => "op-pay-2"
        })
      ])

      report = daily_report("2026-11-30")
      ledger = read_ledger(%{"on" => "2026-11-30"})

      assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) ==
               ledger["cash_held_cents"]

      assert report["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]

      for date <- Date.range(~D[2026-10-01], ~D[2026-11-30]) do
        assert_balanced(daily_report(Date.to_iso8601(date)))
      end
    end

    test "cumulative movements agree with the ledger's cumulative cash totals" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(%{"rooms" => [room("room-a", 15_000), room("room-b", 17_500)]}),
        open_group(%{
          "operation_id" => "op-open-2",
          "group_id" => "group-92",
          "property_id" => "par-rive",
          "arrival_on" => "2027-12-10",
          "departure_on" => "2027-12-13"
        }),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 5_000}),
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 2_000
        }),
        transfer_deposit(%{"occurred_on" => "2026-10-08", "amount_cents" => 1_500}),
        reduce_cash_payment(%{"occurred_on" => "2026-10-09", "amount_cents" => 500}),
        cancel_rooms(%{
          "occurred_on" => "2026-11-20",
          "room_ids" => ["room-a"],
          "refund_method" => "hotel_credit"
        }),
        cancel_group(%{
          "operation_id" => "op-cancel-2",
          "group_id" => "group-92",
          "occurred_on" => "2026-11-21"
        }),
        charge_back_payment(%{
          "operation_id" => "op-chargeback-2",
          "occurred_on" => "2026-11-22",
          "payment_operation_id" => "op-pay-2"
        })
      ])

      totals = cumulative_movements(~D[2026-10-01], ~D[2026-11-30])
      ledger = read_ledger(%{"on" => "2026-11-30"})

      assert totals["received_cents"] == 7_000
      assert totals["refunded_cents"] == ledger["cash_refunded_cents"]
      assert totals["retained_cents"] == ledger["cash_retained_cents"]
      assert totals["converted_to_credit_cents"] == ledger["cash_converted_to_credit_cents"]
      assert totals["reduced_cents"] == ledger["cash_reduced_cents"]
      assert totals["charged_back_cents"] == ledger["cash_charged_back_cents"]
      assert totals["transferred_in_cents"] == totals["transferred_out_cents"]
    end

    test "a lot that is spent, clawed back, partly restored, and expired stays reconciled" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      issue_credit(group_id: "group-a", cash_cents: 2_000, operation_id: "op-cancel-a")
      open_funded_group("group-b")
      apply_credit("group-b", 1_000, "2026-12-01")

      # The lot has 1200 left and owes 2200, so 1200 comes back and 1000 stays owed.
      submit_one(
        charge_back_payment(%{
          "occurred_on" => "2026-12-02",
          "payment_operation_id" => "op-pay-group-a"
        })
      )

      assert read_ledger(%{"on" => "2026-12-02"})["credit_shortfall_cents"] == 1_000

      assert daily_report("2026-12-02")["credit"] == %{
               "opening_liability_cents" => 2_200,
               "movements" => %{@no_credit_movements | "revoked_cents" => 1_200},
               "closing_liability_cents" => 1_000
             }

      # The restored credit is swallowed whole by what the lot still owes.
      submit_one(
        cancel_group(%{
          "operation_id" => "op-cancel-b",
          "group_id" => "group-b",
          "occurred_on" => "2026-12-03"
        })
      )

      assert daily_report("2026-12-03")["credit"] == %{
               "opening_liability_cents" => 1_000,
               "movements" => %{@no_credit_movements | "absorbed_cents" => 1_000},
               "closing_liability_cents" => 0
             }

      # Nothing is left in the lot, so its expiry date passes without a movement.
      assert daily_report("2027-11-27")["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => @no_credit_movements,
               "closing_liability_cents" => 0
             }

      ledger = read_ledger(%{"on" => "2027-11-27"})
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "consecutive days chain across the whole history" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit([
        open_group(),
        record_cash_payment(%{"occurred_on" => "2026-10-04", "amount_cents" => 2_000}),
        cancel_group(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ])

      for date <- Date.range(~D[2026-10-01], ~D[2026-11-25]) do
        today = daily_report(Date.to_iso8601(date))
        tomorrow = daily_report(date |> Date.add(1) |> Date.to_iso8601())

        assert closing_held(today) == opening_held(tomorrow)

        assert today["credit"]["closing_liability_cents"] ==
                 tomorrow["credit"]["opening_liability_cents"]
      end
    end
  end

  describe "operations that report nothing" do
    setup do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))
      submit([open_group(), record_cash_payment(%{"occurred_on" => "2026-10-04"})])
      :ok
    end

    test "a rejected operation leaves no movement" do
      assert %{"status" => "rejected"} =
               submit_one(
                 record_cash_payment(%{
                   "operation_id" => "op-too-much",
                   "occurred_on" => "2026-10-05",
                   "amount_cents" => 99_999_999
                 })
               )

      assert property_cash("2026-10-05", "ams-canal")["movements"] == @no_cash_movements
    end

    test "movements of earlier applied operations survive a later rejection in the batch" do
      submit([
        record_cash_payment(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 500
        }),
        cancel_group(%{"group_id" => "group-missing", "occurred_on" => "2026-10-05"})
      ])

      assert property_cash("2026-10-05", "ams-canal")["movements"] ==
               %{@no_cash_movements | "received_cents" => 500}
    end

    test "a durable retry does not report the movement twice" do
      payment =
        record_cash_payment(%{"operation_id" => "op-pay-2", "occurred_on" => "2026-10-05"})

      assert %{"status" => "applied"} = submit_one(payment)
      assert %{"status" => "applied"} = submit_one(payment)

      assert property_cash("2026-10-05", "ams-canal")["movements"]["received_cents"] == 1_000
    end

    test "reading a report repeatedly changes nothing" do
      before = daily_report("2026-10-04")

      assert daily_report("2026-10-04") == before
      assert daily_report("2026-10-06") == daily_report("2026-10-06")
      assert daily_report("2026-10-04") == before
      assert read_ledger()["cash_held_cents"] == 1_000
    end
  end

  describe "equivalent submissions" do
    test "one batch and separate submissions report the same movements" do
      submit_one(start_finance_reporting(%{"starts_on" => "2026-10-01"}))

      submit(Enum.map(scenario("one"), & &1))

      for operation <- scenario("many"), do: submit_one(operation)

      one = property_cash("2026-11-20", "prop-one")
      many = property_cash("2026-11-20", "prop-many")

      assert Map.delete(one, "property_id") == Map.delete(many, "property_id")
    end
  end

  # One group opened, funded, partly reduced, and cancelled, at a property of its own.
  defp scenario(suffix) do
    group_id = "group-" <> suffix

    [
      open_group(%{
        "operation_id" => "op-open-" <> suffix,
        "group_id" => group_id,
        "property_id" => "prop-" <> suffix
      }),
      record_cash_payment(%{
        "operation_id" => "op-pay-" <> suffix,
        "group_id" => group_id,
        "occurred_on" => "2026-11-20",
        "amount_cents" => 2_000
      }),
      reduce_cash_payment(%{
        "operation_id" => "op-reduce-" <> suffix,
        "occurred_on" => "2026-11-20",
        "payment_operation_id" => "op-pay-" <> suffix,
        "amount_cents" => 500
      }),
      cancel_group(%{
        "operation_id" => "op-cancel-" <> suffix,
        "group_id" => group_id,
        "occurred_on" => "2026-11-20"
      })
    ]
  end

  # A flexible group of the same guest with room enough to take the credit under test.
  defp open_funded_group(group_id, arrival_on \\ "2027-12-10") do
    submit_one(
      open_group(%{
        "operation_id" => "op-open-" <> group_id,
        "group_id" => group_id,
        "property_id" => "par-rive",
        "arrival_on" => arrival_on,
        "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601(),
        "rooms" => [room("room-a", 10_000)]
      })
    )
  end

  defp apply_credit(group_id, amount_cents, occurred_on) do
    submit_one(
      apply_hotel_credit(%{
        "operation_id" => "op-credit-" <> group_id,
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "amount_cents" => amount_cents
      })
    )
  end

  defp cumulative_movements(from, to) do
    for date <- Date.range(from, to),
        entry <- daily_report(Date.to_iso8601(date))["cash"],
        {kind, cents} <- entry["movements"],
        reduce: %{} do
      totals -> Map.update(totals, kind, cents, &(&1 + cents))
    end
  end

  defp closing_held(report),
    do: Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"]))

  defp opening_held(report),
    do: Enum.sum(Enum.map(report["cash"], & &1["opening_held_cents"]))

  # Every property's day adds up, and cash only ever moves between properties, never in or out of
  # the report as a whole.
  defp assert_balanced(report) do
    for entry <- report["cash"] do
      movements = entry["movements"]

      assert entry["closing_held_cents"] ==
               entry["opening_held_cents"] + movements["received_cents"] +
                 movements["transferred_in_cents"] - movements["transferred_out_cents"] -
                 movements["refunded_cents"] - movements["retained_cents"] -
                 movements["converted_to_credit_cents"] - movements["reduced_cents"] -
                 movements["charged_back_cents"]
    end

    assert Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_in_cents"])) ==
             Enum.sum(Enum.map(report["cash"], & &1["movements"]["transferred_out_cents"]))

    credit = report["credit"]
    movements = credit["movements"]

    assert credit["closing_liability_cents"] ==
             credit["opening_liability_cents"] + movements["issued_cents"] -
               movements["expired_cents"] - movements["consumed_cents"] -
               movements["revoked_cents"] - movements["absorbed_cents"]
  end
end
