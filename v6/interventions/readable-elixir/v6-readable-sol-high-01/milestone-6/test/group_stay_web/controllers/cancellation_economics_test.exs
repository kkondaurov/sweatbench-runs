defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  describe "policy versions" do
    test "fixes policy from booking date and exposes the inclusive deadline", %{conn: conn} do
      submit_one(conn, open_operation("legacy", "guest", %{"occurred_on" => "2026-12-31"}))

      submit_one(
        conn,
        open_operation("current", "guest", %{
          "occurred_on" => "2027-01-01",
          "operation_id" => "open-current"
        })
      )

      submit_one(
        conn,
        open_operation("advance", "guest", %{
          "operation_id" => "open-advance",
          "rate_plan" => "advance_purchase"
        })
      )

      legacy = get_group(conn, "legacy")
      assert legacy["policy_version"] == "flex-14"
      assert legacy["refundable_until"] == "2027-02-24"

      current = get_group(conn, "current")
      assert current["policy_version"] == "flex-30"
      assert current["refundable_until"] == "2027-02-08"

      advance = get_group(conn, "advance")
      assert advance["policy_version"] == "advance-nonrefundable"
      assert advance["refundable_until"] == nil

      assert %{"refunded_cents" => 0, "retained_cents" => 0} =
               submit_one(conn, cancel_operation("legacy", "2027-02-24"))
    end

    test "rescheduling recomputes the deadline but does not change policy", %{conn: conn} do
      submit_one(conn, open_operation("group", "guest"))

      result =
        submit_one(conn, %{
          "operation_id" => "move-group",
          "type" => "reschedule_group",
          "occurred_on" => "2027-01-05",
          "group_id" => "group",
          "new_arrival_on" => "2027-05-01"
        })

      assert result["policy_version"] == "flex-30"
      assert result["refundable_until"] == "2027-04-01"
      assert get_group(conn, "group")["policy_version"] == "flex-30"
    end
  end

  describe "cash conversion" do
    test "issues 110% hotel credit and moves the original cash in the ledger", %{conn: conn} do
      submit_one(conn, open_operation("source", "guest"))
      submit_one(conn, cash_operation("source", 1_005))

      result =
        submit_one(
          conn,
          cancel_operation("source", "2027-01-31", %{"refund_method" => "hotel_credit"})
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 1_106

      assert get(conn, "/api/v1/ledger?on=2028-01-31") |> json_response(200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 1_005,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 1_106,
                 "credit_shortfall_cents" => 0
               }
             }

      assert get_credit(conn, "guest", "2028-01-31") == %{
               "guest_id" => "guest",
               "available_cents" => 1_106,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-source",
                   "remaining_cents" => 1_106,
                   "expires_on" => "2028-01-31"
                 }
               ]
             }

      assert get_credit(conn, "guest", "2028-02-01")["available_cents"] == 0

      assert get(conn, "/api/v1/ledger?on=2028-02-01")
             |> json_response(200)
             |> get_in(["data", "credit_liability_cents"]) == 0
    end

    test "rejects hotel credit for a non-refundable cancellation without advancing revision", %{
      conn: conn
    } do
      submit_one(conn, open_operation("group", "guest"))
      submit_one(conn, cash_operation("group", 500))

      result =
        submit_one(
          conn,
          cancel_operation("group", "2027-02-20", %{
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          })
        )

      assert result["code"] == "refund_method_not_available"
      assert get_group(conn, "group")["status"] == "active"
      assert get_group(conn, "group")["revision"] == 2
      assert ledger_value(conn, "cash_held_cents", "2027-02-20") == 500

      stale =
        submit_one(
          conn,
          cancel_operation("group", "2027-02-20", %{
            "operation_id" => "stale-cancel-group",
            "refund_method" => "hotel_credit",
            "expected_revision" => 99
          })
        )

      assert stale["code"] == "stale_revision"
    end
  end

  describe "applying and settling hotel credit" do
    test "consumes earliest-expiring lots and restores their original value", %{conn: conn} do
      issue_credit(conn, "first", "guest", "2027-01-10", 1_000)
      issue_credit(conn, "second", "guest", "2027-02-10", 1_000)

      submit_one(
        conn,
        open_operation("target", "guest", %{
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02"
        })
      )

      assert %{
               "amount_cents" => 1_200,
               "outstanding_deposit_cents" => 800,
               "revision" => 2
             } = submit_one(conn, credit_operation("target", 1_200, "2027-03-01"))

      assert %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 1_200,
               "deposit_paid_cents" => 1_200
             } = get_group(conn, "target")

      credit = get_credit(conn, "guest", "2027-03-01")
      assert credit["available_cents"] == 1_000

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "cancel-second",
                 "remaining_cents" => 1_000,
                 "expires_on" => "2028-02-10"
               }
             ]

      assert ledger_value(conn, "credit_liability_cents", "2027-03-01") == 2_200

      result = submit_one(conn, cancel_operation("target", "2027-04-01"))
      assert result["credit_issued_cents"] == 0
      assert result["refunded_cents"] == 0

      restored = get_credit(conn, "guest", "2027-04-01")
      assert restored["available_cents"] == 2_200
      assert Enum.map(restored["lots"], & &1["remaining_cents"]) == [1_100, 1_100]
      assert ledger_value(conn, "credit_liability_cents", "2027-04-01") == 2_200
    end

    test "expired credit stays liable while applied then expires immediately when restored", %{
      conn: conn
    } do
      issue_credit(conn, "source", "guest", "2027-01-10", 1_000)

      submit_one(
        conn,
        open_operation("target", "guest", %{
          "arrival_on" => "2028-03-15",
          "departure_on" => "2028-03-16"
        })
      )

      submit_one(conn, credit_operation("target", 1_100, "2028-01-10"))

      assert get_credit(conn, "guest", "2028-01-11")["available_cents"] == 0
      assert ledger_value(conn, "credit_liability_cents", "2028-01-11") == 1_100

      submit_one(conn, cancel_operation("target", "2028-01-11"))

      assert get_credit(conn, "guest", "2028-01-11")["available_cents"] == 0
      assert ledger_value(conn, "credit_liability_cents", "2028-01-11") == 0
    end

    test "orders equal-expiry lots and never bonuses restored credit", %{conn: conn} do
      issue_credit(conn, "zulu", "guest", "2027-01-10", 1_000)
      issue_credit(conn, "alpha", "guest", "2027-01-10", 1_000)

      assert Enum.map(get_credit(conn, "guest", "2027-02-01")["lots"], fn lot ->
               lot["source_operation_id"]
             end) == ["cancel-alpha", "cancel-zulu"]

      submit_one(
        conn,
        open_operation("target", "guest", %{
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02"
        })
      )

      submit_one(conn, credit_operation("target", 1_100, "2027-02-01"))
      submit_one(conn, cash_operation("target", 100))

      assert [remaining_lot] = get_credit(conn, "guest", "2027-02-01")["lots"]
      assert remaining_lot["source_operation_id"] == "cancel-zulu"

      result =
        submit_one(
          conn,
          cancel_operation("target", "2027-04-01", %{"refund_method" => "hotel_credit"})
        )

      assert result["credit_issued_cents"] == 110
      assert result["refunded_cents"] == 0
      assert get_credit(conn, "guest", "2027-04-01")["available_cents"] == 2_310
      assert ledger_value(conn, "cash_converted_to_credit_cents", "2027-04-01") == 2_100
    end

    test "non-refundable cancellation consumes applied credit without treating it as cash", %{
      conn: conn
    } do
      issue_credit(conn, "source", "guest", "2027-01-10", 1_000)

      submit_one(
        conn,
        open_operation("target", "guest", %{
          "rate_plan" => "advance_purchase",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02"
        })
      )

      submit_one(conn, credit_operation("target", 1_100, "2027-03-01"))
      result = submit_one(conn, cancel_operation("target", "2027-03-02"))

      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert ledger_value(conn, "credit_liability_cents", "2027-03-02") == 0
      assert ledger_value(conn, "cash_retained_cents", "2027-03-02") == 0
    end

    test "validates revision, amount, outstanding deposit, and available credit in order", %{
      conn: conn
    } do
      submit_one(conn, open_operation("target", "guest"))

      stale =
        credit_operation("target", -1, "2027-01-02")
        |> Map.put("operation_id", "stale-credit-target")
        |> Map.put("expected_revision", 9)
        |> then(&submit_one(conn, &1))

      assert stale["code"] == "stale_revision"

      invalid_amount =
        credit_operation("target", -1, "2027-01-02")
        |> Map.put("operation_id", "invalid-credit-target")

      assert submit_one(conn, invalid_amount)["code"] ==
               "invalid_amount"

      excessive_payment =
        credit_operation("target", 2_001, "2027-01-02")
        |> Map.put("operation_id", "excessive-credit-target")

      assert submit_one(conn, excessive_payment)["code"] ==
               "payment_exceeds_outstanding"

      insufficient_credit =
        credit_operation("target", 1, "2027-01-02")
        |> Map.put("operation_id", "unfunded-credit-target")

      assert submit_one(conn, insufficient_credit)["code"] ==
               "insufficient_credit"

      assert get_group(conn, "target")["revision"] == 1
    end
  end

  describe "reporting dates" do
    test "returns zero credit for an unknown guest and rejects malformed dates", %{conn: conn} do
      assert get_credit(conn, "unknown", "2027-01-01") == %{
               "guest_id" => "unknown",
               "available_cents" => 0,
               "lots" => []
             }

      assert get(conn, "/api/v1/guests/guest/credit?on=nope") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }

      assert get(conn, "/api/v1/ledger?on=nope") |> json_response(422) == %{
               "error" => %{"code" => "invalid_date"}
             }
    end
  end

  defp issue_credit(conn, group_id, guest_id, cancelled_on, cash_cents) do
    submit_one(
      conn,
      open_operation(group_id, guest_id, %{
        "operation_id" => "open-#{group_id}",
        "arrival_on" => Date.add(Date.from_iso8601!(cancelled_on), 60) |> Date.to_iso8601(),
        "departure_on" => Date.add(Date.from_iso8601!(cancelled_on), 61) |> Date.to_iso8601()
      })
    )

    submit_one(conn, cash_operation(group_id, cash_cents))

    submit_one(
      conn,
      cancel_operation(group_id, cancelled_on, %{
        "operation_id" => "cancel-#{group_id}",
        "refund_method" => "hotel_credit"
      })
    )
  end

  defp open_operation(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "hotel",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-11",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp cash_operation(group_id, amount_cents) do
    %{
      "operation_id" => "pay-#{group_id}",
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp credit_operation(group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => "credit-#{group_id}",
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, occurred_on, overrides \\ %{}) do
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

  defp submit_one(conn, operation) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => [operation]})
    |> json_response(200)
    |> get_in(["results", Access.at(0)])
  end

  defp get_group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_credit(conn, guest_id, on) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger_value(conn, field, on) do
    conn
    |> get("/api/v1/ledger?on=#{on}")
    |> json_response(200)
    |> get_in(["data", field])
  end
end
