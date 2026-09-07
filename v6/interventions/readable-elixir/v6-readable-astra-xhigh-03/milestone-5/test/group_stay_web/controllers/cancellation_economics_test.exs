defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query
  import GroupStay.OperationFixtures

  alias GroupStay.Repo
  alias GroupStay.Reservations.{CashEntry, CreditAllocation, CreditLot, Group}

  describe "fixed cancellation policies" do
    test "booking cutoff and inclusive deadlines control cash settlements", %{conn: conn} do
      for {booked, plan, policy, deadline, cancellation_date, refundable?} <- [
            {"2026-12-31", "flexible", "flex-14", "2027-02-15", "2027-02-15", true},
            {"2026-12-31", "flexible", "flex-14", "2027-02-15", "2027-02-16", false},
            {"2027-01-01", "flexible", "flex-30", "2027-01-30", "2027-01-30", true},
            {"2027-01-01", "flexible", "flex-30", "2027-01-30", "2027-01-31", false},
            {"2026-12-31", "advance_purchase", "advance-nonrefundable", nil, "2027-01-01", false},
            {"2027-01-01", "advance_purchase", "advance-nonrefundable", nil, "2027-01-01", false}
          ] do
        id = Enum.join([booked, plan, cancellation_date], "/")

        assert [%{"revision" => 1}, %{"revision" => 2}] =
                 submit(conn, [
                   open_group(%{
                     "group_id" => id,
                     "occurred_on" => booked,
                     "arrival_on" => "2027-03-01",
                     "departure_on" => "2027-03-04",
                     "rate_plan" => plan
                   }),
                   payment(%{"group_id" => id, "occurred_on" => booked})
                 ])

        assert group(conn, id)["policy_version"] == policy
        assert group(conn, id)["refundable_until"] == deadline

        assert [result] =
                 submit(conn, [
                   cancellation(%{"group_id" => id, "occurred_on" => cancellation_date})
                 ])

        assert result["status"] == "applied"
        assert result["revision"] == 3
        assert result["refunded_cents"] == if(refundable?, do: 5_000, else: 0)
        assert result["retained_cents"] == if(refundable?, do: 0, else: 5_000)
        assert result["credit_issued_cents"] == 0
        assert group(conn, id)["policy_version"] == policy
      end
    end

    test "rescheduling retains each policy and moves its deadline across leap day", %{conn: conn} do
      for {booked, plan, policy, deadline} <- [
            {"2026-12-31", "flexible", "flex-14", "2028-02-25"},
            {"2027-01-01", "flexible", "flex-30", "2028-02-09"},
            {"2027-01-01", "advance_purchase", "advance-nonrefundable", nil}
          ] do
        submit(conn, [
          open_group(%{"group_id" => policy, "occurred_on" => booked, "rate_plan" => plan})
        ])

        assert [
                 %{
                   "policy_version" => ^policy,
                   "refundable_until" => ^deadline,
                   "new_arrival_on" => "2028-03-10",
                   "new_departure_on" => "2028-03-13",
                   "revision" => 2
                 }
               ] =
                 submit(conn, [
                   reschedule(%{
                     "group_id" => policy,
                     "occurred_on" => "2028-01-01",
                     "new_arrival_on" => "2028-03-10"
                   })
                 ])

        assert group(conn, policy)["refundable_until"] == deadline
        assert group(conn, policy)["policy_version"] == policy
      end
    end
  end

  describe "credit issuance and reads" do
    test "large credit totals remain exact across available and redeemed balances", %{conn: conn} do
      maximum = 9_223_372_036_854_775_807
      deposit = div(maximum * 20 + 50, 100)
      issued = deposit + div(deposit * 10 + 50, 100)

      for index <- 1..5 do
        id = "large-#{index}"

        assert [_, _, %{"credit_issued_cents" => ^issued}] =
                 submit(conn, [
                   open_group(%{
                     "group_id" => id,
                     "departure_on" => "2026-12-11",
                     "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
                   }),
                   payment(%{"group_id" => id, "amount_cents" => deposit}),
                   cancellation(%{"group_id" => id, "refund_method" => "hotel_credit"})
                 ])
      end

      assert credit(conn, "2026-11-01")["available_cents"] == issued * 5
      assert ledger(conn, "2026-11-01")["credit_liability_cents"] == issued * 5
      assert ledger(conn, "2026-11-01")["cash_converted_to_credit_cents"] == deposit * 5

      assert [_, %{"outstanding_deposit_cents" => 0}] =
               submit(conn, [
                 open_group(%{
                   "group_id" => "large-target",
                   "rate_plan" => "advance_purchase",
                   "departure_on" => "2026-12-11",
                   "rooms" => [%{"room_id" => "large", "nightly_rate_cents" => maximum}]
                 }),
                 credit_application(%{"group_id" => "large-target", "amount_cents" => maximum})
               ])

      assert ledger(conn, "2026-11-01")["credit_liability_cents"] == issued * 5
      assert credit(conn, "2026-11-01")["available_cents"] == issued * 5 - maximum
      assert ledger(conn, "2027-11-02")["credit_liability_cents"] == maximum
    end

    test "converts cash with independently rounded bonuses, including exact half cents", %{
      conn: conn
    } do
      for {cash, issued} <- [{4, 4}, {5, 6}, {6, 7}, {15, 17}] do
        result = issue_credit(conn, "cancel-#{cash}", "2027-03-01", cash)
        assert result["credit_issued_cents"] == issued
        assert result["refunded_cents"] == 0
        assert result["retained_cents"] == 0
        assert result["revision"] == 3
        assert group(conn, "cancel-#{cash}")["cash_paid_cents"] == 0
        assert group(conn, "cancel-#{cash}")["credit_paid_cents"] == 0
      end

      assert credit(conn, "2028-02-29") == %{
               "guest_id" => "guest-22",
               "available_cents" => 34,
               "lots" => [
                 lot("cancel-15", 17, "2028-02-29"),
                 lot("cancel-4", 4, "2028-02-29"),
                 lot("cancel-5", 6, "2028-02-29"),
                 lot("cancel-6", 7, "2028-02-29")
               ]
             }

      assert ledger(conn, "2028-02-29") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0,
               "cash_converted_to_credit_cents" => 30,
               "credit_liability_cents" => 34
             }

      assert credit(conn, "2028-03-01")["lots"] == []
      assert ledger(conn, "2028-03-01")["credit_liability_cents"] == 0
      assert ledger(conn, "2028-03-01")["cash_converted_to_credit_cents"] == 30
    end

    test "refundable cancellation without cash creates no zero-value lot", %{conn: conn} do
      assert [_, %{"credit_issued_cents" => 0, "revision" => 2}] =
               submit(conn, [open_group(), cancellation(%{"refund_method" => "hotel_credit"})])

      assert Repo.all(CreditLot) == []
      assert Repo.all(CashEntry) == []
    end

    test "non-refundable hotel credit is rejected even when no cash is paid", %{conn: conn} do
      for {id, plan, on} <- [
            {"old-flex", "flexible", "2026-11-27"},
            {"advance", "advance_purchase", "2026-11-01"}
          ] do
        submit(conn, [open_group(%{"group_id" => id, "rate_plan" => plan})])
        before = snapshot()

        assert [%{"code" => "refund_method_not_available"}] =
                 submit(conn, [
                   cancellation(%{
                     "group_id" => id,
                     "occurred_on" => on,
                     "refund_method" => "hotel_credit"
                   })
                 ])

        assert snapshot() == before
        assert group(conn, id)["status"] == "active"
      end
    end

    test "reads default to the UTC date, preserve identifiers, and never mutate balances", %{
      conn: conn
    } do
      today = Date.utc_today()
      guest = " Guest-Ä_22 "
      issue_credit(conn, "today", Date.to_iso8601(Date.add(today, -365)), 100, guest)
      issue_credit(conn, "yesterday", Date.to_iso8601(Date.add(today, -366)), 100, guest)
      before = snapshot()

      assert credit(conn, nil, guest) == credit(conn, Date.to_iso8601(today), guest)
      assert credit(conn, nil, guest)["guest_id"] == guest
      assert credit(conn, nil, guest)["lots"] == [lot("today", 110, Date.to_iso8601(today))]
      assert ledger(conn, nil)["credit_liability_cents"] == 110
      assert ledger(conn, Date.to_iso8601(Date.add(today, 1)))["credit_liability_cents"] == 0
      assert ledger(conn, Date.to_iso8601(today))["credit_liability_cents"] == 110

      assert credit(conn, nil, "unknown") == %{
               "guest_id" => "unknown",
               "available_cents" => 0,
               "lots" => []
             }

      assert snapshot() == before
    end

    test "malformed expiry query dates return a consistent client error", %{conn: conn} do
      for path <- ["/api/v1/ledger", "/api/v1/guests/guest-22/credit"],
          query <- ["on=bad", "on=2027-02-29", "on=", "on[]=2027-01-01", "on[date]=2027-01-01"] do
        assert conn |> get(path <> "?" <> query) |> json_response(422) ==
                 %{"error" => %{"code" => "invalid_date"}}
      end
    end
  end

  describe "credit funding and settlement" do
    test "consumes by expiry then operation ID across lots and restores each original lot", %{
      conn: conn
    } do
      issue_credit(conn, "z-later", "2027-02-01", 100)
      issue_credit(conn, "b-first", "2027-01-01", 200)
      issue_credit(conn, "a-first", "2027-01-01", 100)
      issue_credit(conn, "other-guest", "2026-12-01", 1_000, "other")

      assert [
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "group_id" => "target",
                 "amount_cents" => 250,
                 "outstanding_deposit_cents" => 18_750,
                 "revision" => 3
               }
             ] =
               submit(conn, [
                 future_group("target"),
                 payment(%{"group_id" => "target", "amount_cents" => 500}),
                 credit_application(%{
                   "group_id" => "target",
                   "amount_cents" => 250,
                   "occurred_on" => "2027-02-01"
                 })
               ])

      assert group(conn, "target")["deposit_paid_cents"] == 750
      assert group(conn, "target")["cash_paid_cents"] == 500
      assert group(conn, "target")["credit_paid_cents"] == 250

      assert credit(conn, "2027-02-01")["lots"] == [
               lot("b-first", 80, "2028-01-01"),
               lot("z-later", 110, "2028-02-01")
             ]

      assert credit(conn, "2027-02-01", "other")["available_cents"] == 1_100
      assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 1_540
      assert ledger(conn, "2027-02-01")["cash_held_cents"] == 500

      assert [
               %{
                 "refunded_cents" => 500,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] =
               submit(conn, [
                 cancellation(%{
                   "group_id" => "target",
                   "occurred_on" => "2027-02-01",
                   "refund_method" => "cash"
                 })
               ])

      assert credit(conn, "2027-02-01")["lots"] == [
               lot("a-first", 110, "2028-01-01"),
               lot("b-first", 220, "2028-01-01"),
               lot("z-later", 110, "2028-02-01")
             ]

      assert group(conn, "target")["cash_paid_cents"] == 0
      assert group(conn, "target")["credit_paid_cents"] == 0
      assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 1_540
      assert ledger(conn, "2027-02-01")["cash_refunded_cents"] == 500
      assert ledger(conn, "2027-02-01")["cash_held_cents"] == 0
    end

    test "repeated refundable credit settlements bonus only new cash", %{conn: conn} do
      issue_credit(conn, "original", "2027-01-01", 1_000)

      assert [
               _,
               _,
               _,
               _,
               %{
                 "credit_issued_cents" => 6,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "revision" => 5
               }
             ] =
               submit(conn, [
                 future_group("mixed"),
                 credit_application(%{
                   "group_id" => "mixed",
                   "amount_cents" => 400,
                   "occurred_on" => "2027-02-01"
                 }),
                 credit_application(%{
                   "group_id" => "mixed",
                   "amount_cents" => 400,
                   "occurred_on" => "2027-02-01"
                 }),
                 payment(%{"group_id" => "mixed", "amount_cents" => 5}),
                 cancellation(%{
                   "group_id" => "mixed",
                   "operation_id" => "mixed-credit",
                   "occurred_on" => "2027-02-01",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert credit(conn, "2027-02-01")["lots"] == [
               lot("original", 1_100, "2028-01-01"),
               lot("mixed-credit", 6, "2028-02-01")
             ]

      assert ledger(conn, "2027-02-01")["cash_converted_to_credit_cents"] == 1_005
      assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 1_106

      assert [_, %{"outstanding_deposit_cents" => 18_394}, %{"credit_issued_cents" => 0}] =
               submit(conn, [
                 future_group("credit-only"),
                 credit_application(%{
                   "group_id" => "credit-only",
                   "amount_cents" => 1_106,
                   "occurred_on" => "2027-02-02"
                 }),
                 cancellation(%{
                   "group_id" => "credit-only",
                   "occurred_on" => "2027-02-02",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert credit(conn, "2027-02-02")["available_cents"] == 1_106
      assert Repo.aggregate(CreditLot, :count) == 2
    end

    test "non-refundable cancellations consume credit and retain only cash", %{conn: conn} do
      for {id, plan, booked} <- [
            {"flex", "flexible", "2027-01-01"},
            {"advance", "advance_purchase", "2026-12-01"}
          ] do
        issue_credit(conn, "source-#{id}", "2027-01-01", 1_000, id)

        submit(conn, [
          future_group(id, %{"guest_id" => id, "rate_plan" => plan, "occurred_on" => booked}),
          credit_application(%{
            "group_id" => id,
            "amount_cents" => 800,
            "occurred_on" => "2027-02-01"
          }),
          payment(%{"group_id" => id, "amount_cents" => 500})
        ])

        before = snapshot()

        assert [%{"code" => "refund_method_not_available"}] =
                 submit(conn, [
                   cancellation(%{
                     "group_id" => id,
                     "occurred_on" => "2028-06-01",
                     "refund_method" => "hotel_credit"
                   })
                 ])

        assert snapshot() == before

        assert [
                 %{
                   "refunded_cents" => 0,
                   "retained_cents" => 500,
                   "credit_issued_cents" => 0,
                   "revision" => 4
                 }
               ] =
                 submit(conn, [cancellation(%{"group_id" => id, "occurred_on" => "2028-06-01"})])

        assert credit(conn, "2027-02-01", id)["available_cents"] == 300
      end

      assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 600
      assert ledger(conn, "2028-06-01")["credit_liability_cents"] == 0
      assert ledger(conn, "2028-06-01")["cash_retained_cents"] == 1_000
    end

    test "expiry pauses in a deposit and expired restorations reduce liability immediately", %{
      conn: conn
    } do
      issue_credit(conn, "original", "2027-01-01", 1_000)
      issue_credit(conn, "later", "2027-02-01", 1_000)

      submit(conn, [
        future_group("target"),
        credit_application(%{
          "group_id" => "target",
          "amount_cents" => 1_500,
          "occurred_on" => "2028-01-01"
        })
      ])

      assert credit(conn, "2028-01-01")["lots"] == [lot("later", 700, "2028-02-01")]
      assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 2_200
      assert ledger(conn, "2028-02-02")["credit_liability_cents"] == 1_500

      assert [%{"credit_issued_cents" => 0, "revision" => 3}] =
               submit(conn, [
                 cancellation(%{"group_id" => "target", "occurred_on" => "2028-01-02"})
               ])

      assert credit(conn, "2028-01-02")["lots"] == [lot("later", 1_100, "2028-02-01")]
      assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 1_100
      assert ledger(conn, "2028-02-02")["credit_liability_cents"] == 0

      submit(conn, [future_group("after-expiry")])

      assert [%{"code" => "insufficient_credit"}] =
               submit(conn, [
                 credit_application(%{
                   "group_id" => "after-expiry",
                   "amount_cents" => 1,
                   "occurred_on" => "2028-02-02"
                 })
               ])
    end

    test "credit restored on its expiry date is still available to the next batch operation", %{
      conn: conn
    } do
      issue_credit(conn, "original", "2027-01-01", 100)

      assert [_, _, _, %{"credit_issued_cents" => 0}, %{"revision" => 2}] =
               submit(conn, [
                 future_group("first"),
                 future_group("second"),
                 credit_application(%{
                   "group_id" => "first",
                   "amount_cents" => 110,
                   "occurred_on" => "2028-01-01"
                 }),
                 cancellation(%{"group_id" => "first", "occurred_on" => "2028-01-01"}),
                 credit_application(%{
                   "group_id" => "second",
                   "amount_cents" => 110,
                   "occurred_on" => "2028-01-01"
                 })
               ])

      assert credit(conn, "2028-01-01")["lots"] == []
      assert ledger(conn, "2028-01-02")["credit_liability_cents"] == 110
    end
  end

  describe "credit validation and revisions" do
    test "failed attempts preserve domain records and later operations still apply", %{conn: conn} do
      issue_credit(conn, "source", "2027-01-01", 100)
      submit(conn, [future_group("target")])

      for {fields, code} <-
            [
              {%{"amount_cents" => 111}, "insufficient_credit"},
              {%{"amount_cents" => 19_501}, "payment_exceeds_outstanding"},
              {%{"amount_cents" => 1, "occurred_on" => "2028-01-02"}, "insufficient_credit"}
            ] ++
              Enum.map(
                [0, -1, 1.0, "1", nil, true, %{}, 9_223_372_036_854_775_808],
                &{%{"amount_cents" => &1}, "invalid_amount"}
              ) do
        before = snapshot()

        operation =
          credit_application(
            Map.merge(
              %{"group_id" => "target", "occurred_on" => "2027-02-01", "expected_revision" => 1},
              fields
            )
          )

        assert [%{"code" => ^code}] = submit(conn, [operation])
        assert snapshot() == before
      end

      assert [
               %{"code" => "insufficient_credit"},
               %{"revision" => 2},
               %{"code" => "stale_revision", "actual_revision" => 2},
               %{"revision" => 3}
             ] =
               submit(conn, [
                 credit_application(%{
                   "group_id" => "target",
                   "amount_cents" => 111,
                   "occurred_on" => "2027-02-01"
                 }),
                 credit_application(%{
                   "group_id" => "target",
                   "amount_cents" => 110,
                   "occurred_on" => "2027-02-01",
                   "expected_revision" => 1
                 }),
                 cancellation(%{
                   "group_id" => "target",
                   "refund_method" => "bad",
                   "expected_revision" => 1
                 }),
                 payment(%{
                   "group_id" => "target",
                   "amount_cents" => 19_390,
                   "expected_revision" => 2
                 })
               ])

      assert group(conn, "target")["outstanding_deposit_cents"] == 0
      assert ledger(conn, "2027-02-01")["credit_liability_cents"] == 110
    end

    test "existence and revision checks precede new domain rules and missing payloads", %{
      conn: conn
    } do
      operations = [
        credit_application(%{"amount_cents" => -1}),
        credit_application(),
        Map.delete(credit_application(), "amount_cents"),
        cancellation(%{"refund_method" => "bad"}),
        cancellation(%{"refund_method" => "hotel_credit"})
      ]

      for operation <- operations do
        assert [%{"code" => "group_not_found"}] =
                 submit(conn, [Map.put(operation, "expected_revision", 9)])
      end

      submit(conn, [open_group(%{"rate_plan" => "advance_purchase"})])
      before = snapshot()

      for operation <- operations do
        assert [
                 %{
                   "code" => "stale_revision",
                   "expected_revision" => 9,
                   "actual_revision" => 1,
                   "group_id" => "group-81"
                 }
               ] =
                 submit(conn, [
                   Map.merge(operation, %{
                     "operation_id" => unique_operation_id(operation["type"]),
                     "expected_revision" => 9
                   })
                 ])

        assert snapshot() == before
      end

      for method <- [nil, "", "voucher", "CASH", 1, %{}] do
        assert [%{"code" => "invalid_operation"}] =
                 submit(conn, [cancellation(%{"refund_method" => method})])

        assert snapshot() == before
      end

      for field <- Map.keys(credit_application()) do
        assert [%{"code" => "invalid_operation"}] =
                 submit(conn, [Map.delete(credit_application(), field)])
      end

      submit(conn, [cancellation()])

      assert [%{"code" => "stale_revision"}, %{"code" => "group_not_active"}] =
               submit(conn, [
                 credit_application(%{"expected_revision" => 1}),
                 credit_application(%{"expected_revision" => 2})
               ])
    end

    test "credit belongs to the guest and works across properties", %{conn: conn} do
      issue_credit(conn, "original", "2027-01-01", 100)

      assert [_, _, %{"code" => "insufficient_credit"}, %{"outstanding_deposit_cents" => 19_390}] =
               submit(conn, [
                 future_group("other", %{"guest_id" => "other"}),
                 future_group("same", %{"property_id" => "paris"}),
                 credit_application(%{
                   "group_id" => "other",
                   "amount_cents" => 110,
                   "occurred_on" => "2027-02-01"
                 }),
                 credit_application(%{
                   "group_id" => "same",
                   "amount_cents" => 110,
                   "occurred_on" => "2027-02-01"
                 })
               ])
    end
  end

  defp issue_credit(conn, operation_id, on, cash, guest_id \\ "guest-22") do
    date = Date.from_iso8601!(on)

    assert [_, _, %{"status" => "applied"} = result] =
             submit(conn, [
               open_group(%{
                 "group_id" => operation_id,
                 "guest_id" => guest_id,
                 "occurred_on" => on,
                 "arrival_on" => Date.to_iso8601(Date.add(date, 60)),
                 "departure_on" => Date.to_iso8601(Date.add(date, 63))
               }),
               payment(%{
                 "group_id" => operation_id,
                 "occurred_on" => on,
                 "amount_cents" => cash
               }),
               cancellation(%{
                 "group_id" => operation_id,
                 "operation_id" => operation_id,
                 "occurred_on" => on,
                 "refund_method" => "hotel_credit"
               })
             ])

    result
  end

  defp future_group(id, overrides \\ %{}) do
    open_group(
      Map.merge(
        %{
          "group_id" => id,
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2028-06-01",
          "departure_on" => "2028-06-04"
        },
        overrides
      )
    )
  end

  defp lot(source, remaining, expires_on) do
    %{"source_operation_id" => source, "remaining_cents" => remaining, "expires_on" => expires_on}
  end

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(conn, id) do
    conn
    |> get("/api/v1/groups/" <> URI.encode_www_form(id))
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit(conn, on, guest_id \\ "guest-22") do
    read(conn, "/api/v1/guests/#{URI.encode(guest_id)}/credit", on)
  end

  defp ledger(conn, on), do: read(conn, "/api/v1/ledger", on)

  defp read(conn, path, on) do
    params = if on, do: %{"on" => on}, else: %{}
    conn |> get(path, params) |> json_response(200) |> Map.fetch!("data")
  end

  defp snapshot do
    for schema <- [Group, CashEntry, CreditLot, CreditAllocation] do
      Repo.all(from record in schema, order_by: ^schema.__schema__(:primary_key))
    end
  end
end
