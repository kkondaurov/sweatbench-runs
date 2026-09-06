defmodule GroupStayWeb.Acceptance.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  # Two rooms over two nights (flexible, 20% deposit):
  #   room-a lodging 20000 deposit 4000
  #   room-b lodging 30000 deposit 6000
  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 15000}
        ]
      },
      overrides
    )
  end

  defp pay_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp start_op(op_id, starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  defp transfer_op(op_id, source_group_id, destination_group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-02",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp cancel_op(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp cancel_rooms_op(op_id, group_id, room_ids, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "cancel_rooms",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  defp apply_credit_op(op_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-03",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp reduce_op(op_id, payment_operation_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-03",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp charge_back_op(op_id, payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp report(conn, date) do
    conn
    |> get("/api/v1/finance/daily-report", %{"date" => date})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn, on \\ nil) do
    params = if on, do: %{"on" => on}, else: %{}

    conn
    |> get("/api/v1/ledger", params)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "starting finance reporting" do
    test "the first applied start returns exactly operation_id, status, and starts_on" do
      assert [
               %{
                 "operation_id" => "start-1",
                 "status" => "applied",
                 "starts_on" => "2026-11-01"
               } = result
             ] = submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert Map.keys(result) |> Enum.sort() == ["operation_id", "starts_on", "status"]
    end

    test "a different start operation is rejected once reporting has started" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [
               %{
                 "operation_id" => "start-2",
                 "status" => "rejected",
                 "code" => "reporting_already_started"
               }
             ] = submit(build_conn(), [start_op("start-2", "2026-11-02")])
    end

    test "a retry of the original start returns the stored result" do
      [first] = submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert submit(build_conn(), [start_op("start-1", "2026-11-01")]) == [first]
    end

    test "reusing the identifier with a different payload is a conflict" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               submit(build_conn(), [start_op("start-1", "2026-11-02")])
    end

    test "an invalid or missing starts_on is rejected as invalid_reporting_date" do
      assert [%{"status" => "rejected", "code" => "invalid_reporting_date"}] =
               submit(build_conn(), [start_op("start-1", "not-a-date")])

      assert [%{"status" => "rejected", "code" => "invalid_reporting_date"}] =
               submit(build_conn(), [start_op("start-2", "2026-11-01") |> Map.delete("starts_on")])

      assert [%{"status" => "rejected", "code" => "invalid_reporting_date"}] =
               submit(build_conn(), [
                 start_op("start-3", "2026-11-01", %{"starts_on" => 20_261_101})
               ])
    end

    test "an invalid start does not enable reporting" do
      submit(build_conn(), [start_op("start-1", "not-a-date")])

      assert build_conn()
             |> get("/api/v1/finance/daily-report", %{"date" => "2026-11-01"})
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      assert [%{"status" => "applied"}] =
               submit(build_conn(), [start_op("start-2", "2026-11-01")])

      assert %{"date" => "2026-11-01"} = report(build_conn(), "2026-11-01")
    end

    test "a rejected start is remembered durably" do
      submit(build_conn(), [start_op("start-1", "not-a-date")])

      assert submit(build_conn(), [start_op("start-1", "not-a-date")]) == [
               %{
                 "operation_id" => "start-1",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
             ]
    end
  end

  describe "reading one day" do
    test "a missing or invalid date returns 422 invalid_reporting_date" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert build_conn()
             |> get("/api/v1/finance/daily-report")
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      assert build_conn()
             |> get("/api/v1/finance/daily-report", %{"date" => "not-a-date"})
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "date validation happens before availability" do
      assert build_conn()
             |> get("/api/v1/finance/daily-report", %{"date" => "not-a-date"})
             |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}
    end

    test "before reporting has started the report is not available" do
      assert build_conn()
             |> get("/api/v1/finance/daily-report", %{"date" => "2026-11-01"})
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "a date before starts_on is not available" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert build_conn()
             |> get("/api/v1/finance/daily-report", %{"date" => "2026-10-31"})
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "an empty report has the date, open status, empty cash, and zero credit" do
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert %{
               "date" => "2026-11-01",
               "status" => "open",
               "cash" => [],
               "credit" => %{
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
             } = report(build_conn(), "2026-11-01")
    end
  end

  describe "opening position" do
    test "held cash committed before the start opens starts_on" do
      submit(build_conn(), [open_op("group-a"), pay_op("pay-1", "group-a", 5000)])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => %{
                   "received_cents" => 0,
                   "transferred_in_cents" => 0,
                   "transferred_out_cents" => 0,
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "converted_to_credit_cents" => 0,
                   "reduced_cents" => 0,
                   "charged_back_cents" => 0
                 },
                 "closing_held_cents" => 5000
               }
             ] = report(build_conn(), "2026-11-01")["cash"]
    end

    test "operations committed before the start open even when their dates are later" do
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("pay-1", "group-a", 5000, %{"occurred_on" => "2026-11-15"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      assert [%{"opening_held_cents" => 5000, "closing_held_cents" => 5000}] =
               report(build_conn(), "2026-11-01")["cash"]

      # The payment is part of the opening position, not a movement on its own date.
      assert [%{"opening_held_cents" => 5000, "movements" => %{"received_cents" => 0}}] =
               report(build_conn(), "2026-11-15")["cash"]
    end

    test "in one batch, operations before the start open and operations after move" do
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("pay-1", "group-a", 4000),
        start_op("start-1", "2026-11-01"),
        pay_op("pay-2", "group-a", 1000, %{"occurred_on" => "2026-11-01"})
      ])

      assert [
               %{
                 "opening_held_cents" => 4000,
                 "movements" => %{"received_cents" => 1000},
                 "closing_held_cents" => 5000
               }
             ] = report(build_conn(), "2026-11-01")["cash"]
    end

    test "credit liability committed before the start opens the credit position" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

      submit(build_conn(), [
        cancel_op("group-c", "2026-10-20", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      credit = report(build_conn(), "2026-11-01")["credit"]
      assert credit["opening_liability_cents"] == 4400
      assert credit["closing_liability_cents"] == 4400
    end
  end

  describe "cash movements" do
    setup do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{"property_id" => "nyc-east"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      :ok
    end

    test "a payment posts received on its property and date" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 5000, %{"occurred_on" => "2026-11-02"})])

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => %{"received_cents" => 5000},
                 "closing_held_cents" => 5000
               }
             ] = report(build_conn(), "2026-11-02")["cash"]

      # The next day opens with the previous closing.
      assert [%{"opening_held_cents" => 5000, "closing_held_cents" => 5000}] =
               report(build_conn(), "2026-11-03")["cash"]
    end

    test "a transfer posts equal out and in on the two properties" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 5000)])
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      [ams, nyc] = report(build_conn(), "2026-11-02")["cash"]

      assert ams["property_id"] == "ams-canal"
      assert ams["opening_held_cents"] == 5000
      assert ams["movements"]["transferred_out_cents"] == 2000
      assert ams["closing_held_cents"] == 3000

      assert nyc["property_id"] == "nyc-east"
      assert nyc["movements"]["transferred_in_cents"] == 2000
      assert nyc["closing_held_cents"] == 2000
    end

    test "refundable and non-refundable settlements post refunded and retained" do
      submit(build_conn(), [pay_op("pay-a", "group-a", 4000), pay_op("pay-b", "group-b", 6000)])

      # flex-14: refundable until 2026-11-26.
      submit(build_conn(), [cancel_op("group-a", "2026-11-05")])
      submit(build_conn(), [cancel_op("group-b", "2026-12-01")])

      day = report(build_conn(), "2026-11-05")["cash"]
      ams = Enum.find(day, &(&1["property_id"] == "ams-canal"))
      assert ams["movements"]["refunded_cents"] == 4000
      assert ams["closing_held_cents"] == 0
      # nyc-east still holds its opening on that date.
      assert length(day) == 2

      assert [
               %{
                 "property_id" => "nyc-east",
                 "movements" => %{"retained_cents" => 6000},
                 "closing_held_cents" => 0
               }
             ] = report(build_conn(), "2026-12-01")["cash"]
    end

    test "a credit settlement posts converted_to_credit" do
      submit(build_conn(), [pay_op("pay-a", "group-a", 4000)])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-05", %{"refund_method" => "hotel_credit"})
      ])

      data = report(build_conn(), "2026-11-05")

      assert [%{"movements" => %{"converted_to_credit_cents" => 4000}, "closing_held_cents" => 0}] =
               data["cash"]

      assert data["credit"]["movements"]["issued_cents"] == 4400
      assert data["credit"]["closing_liability_cents"] == 4400
    end

    test "a transfer of mixed funding moves only the cash portion through cash" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [pay_op("pay-1", "group-a", 4000, %{"occurred_on" => "2026-11-02"})])

      submit(build_conn(), [
        apply_credit_op("credit-a", "group-a", 2000, %{"occurred_on" => "2026-11-02"})
      ])

      # group-a holds cash 4000 and credit 2000; the transfer draws the most
      # recent allocations first, so all 2000 credit and only 1000 cash move.
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 3000)])

      [ams, nyc] = report(build_conn(), "2026-11-02")["cash"]
      assert ams["movements"]["transferred_out_cents"] == 1000
      assert nyc["movements"]["transferred_in_cents"] == 1000
      assert nyc["closing_held_cents"] == 1000

      # The moved credit changes no liability and reports no movement.
      credit = report(build_conn(), "2026-11-02")["credit"]
      assert credit["movements"]["issued_cents"] == 4400
      assert credit["closing_liability_cents"] == 4400
    end

    test "a room-level settlement posts the selected rooms' cash only" do
      submit(build_conn(), [pay_op("pay-a", "group-a", 10000)])

      # Rooms hold 4000 (room-a) and 6000 (room-b); cancelling room-a alone
      # refunds only its allocation.
      submit(build_conn(), [cancel_rooms_op("rooms-1", "group-a", ["room-a"], "2026-11-05")])

      day = report(build_conn(), "2026-11-05")

      assert [%{"movements" => %{"refunded_cents" => 4000}, "closing_held_cents" => 6000}] =
               day["cash"]
    end

    test "a reduction spanning two properties reports each property's share" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 5000)])
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])

      # Held: 3000 on ams-canal, 2000 on nyc-east; reducing 4000 removes the
      # newest (nyc-east 2000) first, then 2000 from ams-canal.
      submit(build_conn(), [reduce_op("reduce-1", "pay-1", 4000)])

      [ams, nyc] = report(build_conn(), "2026-11-03")["cash"]
      assert ams["movements"]["reduced_cents"] == 2000
      assert ams["closing_held_cents"] == 1000
      assert nyc["movements"]["reduced_cents"] == 2000
      assert nyc["closing_held_cents"] == 0
    end

    test "a reduction follows held cash to the property where it is held" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 5000)])
      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])
      submit(build_conn(), [reduce_op("reduce-1", "pay-1", 1500)])

      # The reduction removes the newest allocations first: the cash now held
      # by group-b at nyc-east, not the payment's original property.
      [ams, nyc] = report(build_conn(), "2026-11-03")["cash"]
      assert ams["movements"]["reduced_cents"] == 0
      assert ams["closing_held_cents"] == 3000
      assert nyc["movements"]["reduced_cents"] == 1500
      assert nyc["closing_held_cents"] == 500
    end

    test "a chargeback reverses an earlier refund and reports charged back" do
      submit(build_conn(), [pay_op("pay-1", "group-a", 4000)])
      submit(build_conn(), [cancel_op("group-a", "2026-11-05")])
      submit(build_conn(), [charge_back_op("cb-1", "pay-1", %{"occurred_on" => "2026-11-06"})])

      assert [%{"movements" => %{"refunded_cents" => 4000}}] =
               report(build_conn(), "2026-11-05")["cash"]

      assert [
               %{
                 "movements" => %{"refunded_cents" => -4000, "charged_back_cents" => 4000},
                 "closing_held_cents" => 0
               }
             ] = report(build_conn(), "2026-11-06")["cash"]
    end

    test "cash entries are ordered by property_id and zero properties are omitted" do
      submit(build_conn(), [pay_op("pay-b", "group-b", 1000), pay_op("pay-a", "group-a", 1000)])

      assert Enum.map(report(build_conn(), "2026-11-01")["cash"], & &1["property_id"]) ==
               ["ams-canal", "nyc-east"]

      # Settle group-b; nyc-east then has no opening, movements, or closing.
      submit(build_conn(), [cancel_op("group-b", "2026-11-05")])

      assert [%{"property_id" => "ams-canal"}] = report(build_conn(), "2026-11-06")["cash"]
    end
  end

  describe "posting dates" do
    test "a movement posts on the later of occurred_on and starts_on" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])

      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-10-15"})])
      submit(build_conn(), [pay_op("pay-2", "group-a", 1000, %{"occurred_on" => "2026-11-09"})])

      assert [%{"movements" => %{"received_cents" => 1000}}] =
               report(build_conn(), "2026-11-01")["cash"]

      assert [%{"movements" => %{"received_cents" => 1000}}] =
               report(build_conn(), "2026-11-09")["cash"]

      assert [%{"opening_held_cents" => 2000, "closing_held_cents" => 2000}] =
               report(build_conn(), "2026-11-10")["cash"]
    end

    test "a later submission can change an earlier open report" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])

      assert report(build_conn(), "2026-11-02")["cash"] == []

      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-02"})])

      assert [%{"movements" => %{"received_cents" => 1000}}] =
               report(build_conn(), "2026-11-02")["cash"]
    end

    test "all finance effects of one operation use the same posting date" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{"property_id" => "nyc-east"}),
        pay_op("pay-1", "group-a", 5000),
        start_op("start-1", "2026-11-01")
      ])

      # A transfer with a pre-start date posts both legs on starts_on.
      submit(build_conn(), [
        transfer_op("transfer-1", "group-a", "group-b", 2000, %{"occurred_on" => "2026-10-20"})
      ])

      [ams, nyc] = report(build_conn(), "2026-11-01")["cash"]
      assert ams["movements"]["transferred_out_cents"] == 2000
      assert nyc["movements"]["transferred_in_cents"] == 2000
    end
  end

  describe "credit movements" do
    test "issuing, applying, and consuming credit" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      # Converting 4000 cash issues a 4400 lot.
      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      issued_day = report(build_conn(), "2026-11-02")["credit"]
      assert issued_day["opening_liability_cents"] == 0
      assert issued_day["movements"]["issued_cents"] == 4400
      assert issued_day["closing_liability_cents"] == 4400

      # Applying credit changes no liability and reports no movement.
      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])

      apply_day = report(build_conn(), "2026-11-03")["credit"]

      assert apply_day["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert apply_day["closing_liability_cents"] == 4400

      # Non-refundable settlement consumes the applied credit.
      submit(build_conn(), [cancel_op("group-a", "2026-12-05")])

      consumed_day = report(build_conn(), "2026-12-05")["credit"]
      assert consumed_day["movements"]["consumed_cents"] == 2000
      assert consumed_day["closing_liability_cents"] == 2400
    end

    test "unused credit expires on its expiry date without an operation" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-12-01")])

      # The lot's expires_on is 2027-11-03.
      assert report(build_conn(), "2027-11-02")["credit"]["closing_liability_cents"] == 4400

      expiry_day = report(build_conn(), "2027-11-03")["credit"]
      assert expiry_day["opening_liability_cents"] == 4400
      assert expiry_day["movements"]["expired_cents"] == 4400
      assert expiry_day["closing_liability_cents"] == 0

      assert report(build_conn(), "2027-11-04")["credit"]["opening_liability_cents"] == 0
    end

    test "a later submission changes the expired amount on an earlier open report" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-12-01")])

      assert report(build_conn(), "2027-11-03")["credit"]["movements"]["expired_cents"] == 4400

      # Consumed before the expiry in domain time, submitted afterwards.
      submit(build_conn(), [
        apply_credit_op("credit-a", "group-a", 2000, %{"occurred_on" => "2027-11-01"})
      ])

      expiry_day = report(build_conn(), "2027-11-03")["credit"]
      assert expiry_day["movements"]["expired_cents"] == 2400
      assert expiry_day["closing_liability_cents"] == 2000
    end

    test "a chargeback revokes the entitlement created by a conversion" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [charge_back_op("cb-c", "pay-c")])

      data = report(build_conn(), "2026-11-04")
      assert data["credit"]["movements"]["revoked_cents"] == 4400
      assert data["credit"]["closing_liability_cents"] == 0

      # The converted principal reverses and becomes charged-back cash.
      assert [entry] = data["cash"]
      assert entry["movements"]["converted_to_credit_cents"] == -4000
      assert entry["movements"]["charged_back_cents"] == 4000
      assert entry["closing_held_cents"] == 0
    end

    test "a restoration absorbed by a shortfall reports absorbed" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 3000)])

      # Leaves a 3000 clawback covered by the credit applied to group-a.
      submit(build_conn(), [charge_back_op("cb-c", "pay-c")])

      chargeback_day = report(build_conn(), "2026-11-04")["credit"]
      assert chargeback_day["movements"]["revoked_cents"] == 1400
      assert chargeback_day["closing_liability_cents"] == 3000

      # Refundable settlement restores the credit; the shortfall absorbs it.
      submit(build_conn(), [cancel_op("group-a", "2026-11-20")])

      absorbed_day = report(build_conn(), "2026-11-20")["credit"]
      assert absorbed_day["movements"]["absorbed_cents"] == 3000
      assert absorbed_day["closing_liability_cents"] == 0
    end

    test "restoring credit to an unexpired lot reports no movement" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 2000)])
      submit(build_conn(), [cancel_op("group-a", "2026-11-20")])

      restored_day = report(build_conn(), "2026-11-20")["credit"]

      assert restored_day["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert restored_day["closing_liability_cents"] == 4400
    end
  end

  describe "reconciliation" do
    test "closing held follows the cash equation and reconciles with the ledger" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-b", %{"property_id" => "nyc-east"}),
        pay_op("pay-1", "group-a", 7000),
        start_op("start-1", "2026-11-01")
      ])

      submit(build_conn(), [transfer_op("transfer-1", "group-a", "group-b", 2000)])
      submit(build_conn(), [reduce_op("reduce-1", "pay-1", 1000)])
      submit(build_conn(), [cancel_op("group-b", "2026-11-05")])

      transfer_day = report(build_conn(), "2026-11-02")["cash"]

      in_total = Enum.reduce(transfer_day, 0, &(&1["movements"]["transferred_in_cents"] + &2))
      out_total = Enum.reduce(transfer_day, 0, &(&1["movements"]["transferred_out_cents"] + &2))
      assert in_total == out_total and in_total == 2000

      data = report(build_conn(), "2026-11-05")

      Enum.each(data["cash"], fn entry ->
        m = entry["movements"]

        assert entry["closing_held_cents"] ==
                 entry["opening_held_cents"] + m["received_cents"] +
                   m["transferred_in_cents"] - m["transferred_out_cents"] -
                   m["refunded_cents"] - m["retained_cents"] -
                   m["converted_to_credit_cents"] - m["reduced_cents"] - m["charged_back_cents"]
      end)

      total_closing = Enum.reduce(data["cash"], 0, &(&1["closing_held_cents"] + &2))
      assert total_closing == ledger(build_conn())["cash_held_cents"]
    end

    test "closing liability reconciles with the ledger as of the report date" do
      submit(build_conn(), [
        open_op("group-a"),
        open_op("group-c"),
        pay_op("pay-c", "group-c", 4000)
      ])

      submit(build_conn(), [start_op("start-1", "2026-11-01")])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [apply_credit_op("credit-a", "group-a", 1500)])

      data = report(build_conn(), "2026-11-03")
      assert data["credit"]["closing_liability_cents"] == 4400

      assert data["credit"]["closing_liability_cents"] ==
               ledger(build_conn(), "2026-11-03")["credit_liability_cents"]
    end

    test "credit expiry reconciles with the ledger across the expiry date" do
      submit(build_conn(), [open_op("group-c"), pay_op("pay-c", "group-c", 4000)])

      submit(build_conn(), [
        cancel_op("group-c", "2026-11-02", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [start_op("start-1", "2026-12-01")])

      # The lot's expires_on is 2027-11-03; the ledger stops counting it on
      # that date, and so must the report.
      for date <- ["2027-11-02", "2027-11-03", "2027-11-04"] do
        report_value = report(build_conn(), date)["credit"]["closing_liability_cents"]
        ledger_value = ledger(build_conn(), date)["credit_liability_cents"]

        assert report_value == ledger_value,
               "closing liability on #{date}: report=#{report_value} ledger=#{ledger_value}"
      end
    end

    test "settlement movements reconcile with the payment statement" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 5000, %{"occurred_on" => "2026-11-01"})])
      submit(build_conn(), [cancel_op("group-a", "2026-11-05")])
      submit(build_conn(), [charge_back_op("cb-1", "pay-1", %{"occurred_on" => "2026-11-06"})])

      # Received 5000, refunded 5000, then the refund reversed into 5000
      # charged back: the net movements match the statement's disposition.
      statement =
        build_conn()
        |> get("/api/v1/payments/pay-1")
        |> json_response(200)
        |> Map.fetch!("data")

      assert statement["charged_back_cents"] == 5000
      assert statement["refunded_cents"] == 0
      assert ledger(build_conn())["cash_charged_back_cents"] == 5000
    end
  end

  describe "durability" do
    test "a retry does not report a movement twice" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-02"})])
      submit(build_conn(), [pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-02"})])

      assert [%{"movements" => %{"received_cents" => 1000}, "closing_held_cents" => 1000}] =
               report(build_conn(), "2026-11-02")["cash"]
    end

    test "a rejected operation leaves no reporting movement" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 99999, %{"occurred_on" => "2026-11-02"})])

      assert report(build_conn(), "2026-11-02")["cash"] == []
      assert report(build_conn(), "2026-11-02")["credit"]["closing_liability_cents"] == 0
    end

    test "earlier applied movements remain when a later batch operation is rejected" do
      submit(build_conn(), [open_op("group-a"), start_op("start-1", "2026-11-01")])

      submit(build_conn(), [
        pay_op("pay-1", "group-a", 1000, %{"occurred_on" => "2026-11-02"}),
        pay_op("pay-2", "group-a", 99999, %{"occurred_on" => "2026-11-02"})
      ])

      assert [%{"movements" => %{"received_cents" => 1000}}] =
               report(build_conn(), "2026-11-02")["cash"]
    end

    test "reading reports in any order never changes them or the domain state" do
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("pay-1", "group-a", 4000),
        start_op("start-1", "2026-11-01"),
        pay_op("pay-2", "group-a", 1000, %{"occurred_on" => "2026-11-03"})
      ])

      late = report(build_conn(), "2026-11-03")
      early = report(build_conn(), "2026-11-01")
      assert report(build_conn(), "2026-11-03") == late
      assert report(build_conn(), "2026-11-01") == early

      assert ledger(build_conn())["cash_held_cents"] == 5000
    end

    test "sequential submissions produce a deterministic report" do
      submit(build_conn(), [open_op("group-a")])
      submit(build_conn(), [pay_op("pay-1", "group-a", 2500)])
      submit(build_conn(), [start_op("start-1", "2026-11-01")])
      submit(build_conn(), [pay_op("pay-2", "group-a", 500, %{"occurred_on" => "2026-11-01"})])

      assert %{
               "date" => "2026-11-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 2500,
                   "movements" => %{
                     "received_cents" => 500,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 3000
                 }
               ],
               "credit" => %{
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
             } = report(build_conn(), "2026-11-01")
    end
  end
end
