defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  defp post_operations(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open(id, property, options \\ []) do
    %{
      "operation_id" => "open-#{id}",
      "type" => "open_group",
      "occurred_on" => Keyword.get(options, :occurred_on, "2026-01-01"),
      "group_id" => id,
      "guest_id" => Keyword.get(options, :guest_id, "guest-1"),
      "property_id" => property,
      "arrival_on" => Keyword.get(options, :arrival_on, "2027-06-01"),
      "departure_on" => Keyword.get(options, :departure_on, "2027-06-02"),
      "rate_plan" => Keyword.get(options, :rate_plan, "flexible"),
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 50_000}]
    }
  end

  defp payment(id, group, amount, occurred_on \\ "2026-01-02") do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => group,
      "amount_cents" => amount
    }
  end

  defp start(id \\ "start", starts_on \\ "2026-02-01") do
    %{
      "operation_id" => id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp report(date, status \\ 200) do
    response = get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
    json_response(response, status)
  end

  test "takes its opening position in batch order and clamps later operations to starts_on" do
    assert [_, _, start_result, payment_result] =
             post_operations([
               open("group", "z-property"),
               payment("before-start", "group", 3_000, "2026-03-01"),
               start(),
               payment("after-start", "group", 2_000, "2026-01-15")
             ])

    assert start_result == %{
             "operation_id" => "start",
             "status" => "applied",
             "starts_on" => "2026-02-01"
           }

    assert payment_result["status"] == "applied"

    assert %{
             "data" => %{
               "date" => "2026-02-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "z-property",
                   "opening_held_cents" => 3_000,
                   "movements" => %{
                     "received_cents" => 2_000,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 5_000
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
             }
           } = report("2026-02-01")
  end

  test "reports cash transfers and later corrections where the cash is held" do
    post_operations([
      open("source", "b-source"),
      open("destination", "a-destination"),
      start(),
      payment("payment", "source", 4_000, "2026-02-02"),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-02-03",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 1_500
      },
      %{
        "operation_id" => "reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-02-04",
        "payment_operation_id" => "payment",
        "amount_cents" => 1_000
      }
    ])

    assert %{"data" => %{"cash" => cash}} = report("2026-02-03")

    assert cash == [
             %{
               "property_id" => "a-destination",
               "opening_held_cents" => 0,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 1_500,
                 "transferred_out_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 1_500
             },
             %{
               "property_id" => "b-source",
               "opening_held_cents" => 4_000,
               "movements" => %{
                 "received_cents" => 0,
                 "transferred_in_cents" => 0,
                 "transferred_out_cents" => 1_500,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 0,
                 "charged_back_cents" => 0
               },
               "closing_held_cents" => 2_500
             }
           ]

    assert %{"data" => %{"cash" => [destination, source]}} = report("2026-02-04")
    assert destination["movements"]["reduced_cents"] == 1_000
    assert destination["closing_held_cents"] == 500
    assert source["movements"]["reduced_cents"] == 0
  end

  test "reports issued and consumed liability and synthesizes unused credit expiry" do
    post_operations([
      open("origin", "hotel"),
      payment("cash", "origin", 5_000),
      start(),
      %{
        "operation_id" => "issue",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-02",
        "group_id" => "origin",
        "refund_method" => "hotel_credit"
      },
      open("nonrefundable", "hotel", rate_plan: "advance_purchase", guest_id: "guest-1"),
      %{
        "operation_id" => "apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-02-03",
        "group_id" => "nonrefundable",
        "amount_cents" => 2_000
      },
      %{
        "operation_id" => "consume",
        "type" => "cancel_group",
        "occurred_on" => "2026-02-04",
        "group_id" => "nonrefundable"
      }
    ])

    issue_report = report("2026-02-02")["data"]
    assert issue_report["credit"]["movements"]["issued_cents"] == 5_500
    assert issue_report["credit"]["closing_liability_cents"] == 5_500

    consume_report = report("2026-02-04")["data"]
    assert consume_report["credit"]["movements"]["consumed_cents"] == 2_000
    assert consume_report["credit"]["closing_liability_cents"] == 3_500

    expiry_report = report("2027-02-03")["data"]
    assert expiry_report["credit"]["movements"]["expired_cents"] == 3_500
    assert expiry_report["credit"]["closing_liability_cents"] == 0
  end

  test "chargebacks reverse settlement at its destination property and revoke available credit" do
    post_operations([
      open("source", "source-property"),
      open("destination", "destination-property"),
      payment("cash", "source", 5_000),
      %{
        "operation_id" => "transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-01-03",
        "source_group_id" => "source",
        "destination_group_id" => "destination",
        "amount_cents" => 5_000
      },
      %{
        "operation_id" => "convert",
        "type" => "cancel_group",
        "occurred_on" => "2026-01-04",
        "group_id" => "destination",
        "refund_method" => "hotel_credit"
      },
      start(),
      %{
        "operation_id" => "chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-02-02",
        "payment_operation_id" => "cash"
      }
    ])

    data = report("2026-02-02")["data"]

    assert [cash] = data["cash"]
    assert cash["property_id"] == "destination-property"
    assert cash["opening_held_cents"] == 0
    assert cash["movements"]["converted_to_credit_cents"] == -5_000
    assert cash["movements"]["charged_back_cents"] == 5_000
    assert cash["closing_held_cents"] == 0

    assert data["credit"]["opening_liability_cents"] == 5_500
    assert data["credit"]["movements"]["revoked_cents"] == 5_500
    assert data["credit"]["closing_liability_cents"] == 0
  end

  test "validates availability and preserves the start operation durably" do
    assert %{"error" => %{"code" => "invalid_reporting_date"}} =
             get(build_conn(), "/api/v1/finance/daily-report") |> json_response(422)

    assert %{"error" => %{"code" => "invalid_reporting_date"}} = report("not-a-date", 422)
    assert %{"error" => %{"code" => "report_not_available"}} = report("2026-02-01", 404)

    operation = start()
    assert [result] = post_operations([operation])
    assert post_operations([operation]) == [result]

    assert [%{"code" => "operation_id_conflict"}] =
             post_operations([Map.put(operation, "starts_on", "2026-02-02")])

    assert [%{"code" => "reporting_already_started"}] =
             post_operations([start("another-start", "2026-02-02")])

    assert %{"error" => %{"code" => "report_not_available"}} = report("2026-01-31", 404)
  end
end
