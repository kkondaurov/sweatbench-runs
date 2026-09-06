defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  describe "moving held funding" do
    test "moves mixed funding in reverse allocation order without changing the ledger", %{
      conn: conn
    } do
      setup =
        credit_lot_operations() ++
          [
            open_operation("open-source", "source", [500, 1_000]),
            payment_operation("pay-early", "source", 80),
            credit_operation("credit-source", "source", 100),
            payment_operation("pay-late", "source", 50),
            open_operation("open-destination", "destination", [1_000])
          ]

      assert %{"results" => results} = conn |> post_batch(setup) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))
      ledger_before = get_ledger()

      transfer =
        transfer_operation("transfer-mixed", "source", "destination", 120)
        |> Map.put("expected_revision", 4)
        |> Map.put("destination_expected_revision", 1)

      assert %{"results" => [moved]} =
               build_conn() |> post_batch([transfer]) |> json_response(200)

      assert moved == %{
               "operation_id" => "transfer-mixed",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 120,
               "source_outstanding_deposit_cents" => 190,
               "destination_outstanding_deposit_cents" => 80,
               "source_revision" => 5,
               "destination_revision" => 2
             }

      assert %{"data" => source} = get_group("source")
      assert source["cash_paid_cents"] == 80
      assert source["credit_paid_cents"] == 30

      assert %{"data" => destination} = get_group("destination")
      assert destination["cash_paid_cents"] == 50
      assert destination["credit_paid_cents"] == 70
      assert get_ledger() == ledger_before

      assert %{"data" => early_statement} = get_payment("pay-early")
      refute Map.has_key?(early_statement, "held_by_group")

      assert %{
               "data" => %{
                 "held_cents" => 50,
                 "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 50}]
               }
             } = get_payment("pay-late")

      assert build_conn() |> post_batch([transfer]) |> json_response(200) == %{
               "results" => [moved]
             }

      assert get_group("destination") |> get_in(["data", "deposit_paid_cents"]) == 120
    end

    test "preserves transferred hotel credit and restores it to its original lot", %{conn: conn} do
      operations =
        credit_lot_operations() ++
          [
            open_operation("open-credit-source", "credit-source", [500]),
            credit_operation("apply-credit-source", "credit-source", 100),
            open_operation("open-credit-destination", "credit-destination", [500]),
            transfer_operation("transfer-credit", "credit-source", "credit-destination", 100),
            %{
              "operation_id" => "cancel-credit-destination",
              "type" => "cancel_group",
              "occurred_on" => "2027-02-04",
              "group_id" => "credit-destination"
            }
          ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "data" => %{
                 "available_cents" => 110,
                 "lots" => [
                   %{
                     "source_operation_id" => "make-credit",
                     "remaining_cents" => 110,
                     "expires_on" => "2028-02-01"
                   }
                 ]
               }
             } = get_credit("2027-02-04")

      assert %{"data" => %{"credit_liability_cents" => 110}} = get_ledger()
    end

    test "settles transferred cash under the destination policy and applies its credit bonus", %{
      conn: conn
    } do
      source =
        open_operation("open-policy-source", "policy-source", [100])
        |> Map.put("rate_plan", "advance_purchase")

      operations = [
        source,
        payment_operation("pay-policy-source", "policy-source", 100),
        open_operation("open-policy-destination", "policy-destination", [500]),
        transfer_operation("transfer-policy", "policy-source", "policy-destination", 100),
        %{
          "operation_id" => "convert-at-destination",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-04",
          "group_id" => "policy-destination",
          "refund_method" => "hotel_credit"
        }
      ]

      assert %{"results" => [_, _, _, _, settlement]} =
               conn |> post_batch(operations) |> json_response(200)

      assert settlement["status"] == "applied"
      assert settlement["credit_issued_cents"] == 110
      assert settlement["refunded_cents"] == 0
      assert settlement["retained_cents"] == 0

      assert %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_converted_to_credit_cents" => 100,
                 "credit_liability_cents" => 110
               }
             } = get_ledger()

      assert %{
               "data" => %{
                 "converted_to_credit_cents" => 100,
                 "held_by_group" => []
               }
             } = get_payment("pay-policy-source")
    end
  end

  describe "corrections after transfers" do
    test "reduces a payment across groups in reverse allocation order and revises each group once",
         %{
           conn: conn
         } do
      operations = [
        open_operation("open-reduce-source", "reduce-source", [500, 500]),
        payment_operation("pay-transfer-reduce", "reduce-source", 150),
        open_operation("open-reduce-destination", "reduce-destination", [1_000]),
        transfer_operation("transfer-before-reduce", "reduce-source", "reduce-destination", 100)
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      reduction = %{
        "operation_id" => "reduce-transferred",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2027-02-05",
        "payment_operation_id" => "pay-transfer-reduce",
        "amount_cents" => 120,
        "expected_revision" => 3
      }

      assert %{"results" => [result]} =
               build_conn() |> post_batch([reduction]) |> json_response(200)

      assert result == %{
               "operation_id" => "reduce-transferred",
               "status" => "applied",
               "payment_operation_id" => "pay-transfer-reduce",
               "group_id" => "reduce-source",
               "amount_cents" => 120,
               "outstanding_deposit_cents" => 170,
               "revision" => 4
             }

      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 0}} =
               get_group("reduce-destination")

      assert %{
               "data" => %{
                 "held_cents" => 30,
                 "reduced_cents" => 120,
                 "held_by_group" => [%{"group_id" => "reduce-source", "amount_cents" => 30}]
               }
             } = get_payment("pay-transfer-reduce")

      assert %{"data" => %{"cash_held_cents" => 30, "cash_reduced_cents" => 120}} =
               get_ledger()
    end

    test "chargeback reclassifies cash settled under the destination and revises both groups", %{
      conn: conn
    } do
      operations = [
        open_operation("open-charge-source", "charge-source", [500]),
        payment_operation("pay-transfer-charge", "charge-source", 100),
        open_operation("open-charge-destination", "charge-destination", [500]),
        transfer_operation("transfer-before-charge", "charge-source", "charge-destination", 100),
        %{
          "operation_id" => "cancel-charge-destination",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-01",
          "group_id" => "charge-destination"
        }
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      chargeback = %{
        "operation_id" => "charge-transferred",
        "type" => "charge_back_payment",
        "occurred_on" => "2027-02-02",
        "payment_operation_id" => "pay-transfer-charge",
        "expected_revision" => 3
      }

      assert %{"results" => [%{"status" => "applied", "revision" => 4}]} =
               build_conn() |> post_batch([chargeback]) |> json_response(200)

      assert %{"data" => %{"revision" => 4}} = get_group("charge-destination")

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 100
               }
             } = get_ledger()

      assert %{
               "data" => %{
                 "refunded_cents" => 0,
                 "charged_back_cents" => 100,
                 "held_by_group" => []
               }
             } = get_payment("pay-transfer-charge")
    end

    test "telescopes credit entitlement in transferred chunk order", %{conn: conn} do
      source =
        open_operation("open-chunk-source", "chunk-source", [15])
        |> Map.put("rate_plan", "advance_purchase")

      operations = [
        source,
        payment_operation("chunk-payment-a", "chunk-source", 10),
        open_operation("open-chunk-destination", "chunk-destination", [75]),
        transfer_operation("transfer-first-a", "chunk-source", "chunk-destination", 5),
        payment_operation("chunk-payment-b", "chunk-source", 5),
        transfer_operation("transfer-b-then-a", "chunk-source", "chunk-destination", 10),
        %{
          "operation_id" => "convert-chunk-order",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-04",
          "group_id" => "chunk-destination",
          "refund_method" => "hotel_credit"
        },
        %{
          "operation_id" => "charge-chunk-b",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-02-05",
          "payment_operation_id" => "chunk-payment-b",
          "expected_revision" => 5
        }
      ]

      assert %{"results" => [_, _, _, _, _, _, converted, charged]} =
               conn |> post_batch(operations) |> json_response(200)

      assert converted["credit_issued_cents"] == 17
      assert charged["charged_back_cents"] == 5

      assert %{
               "data" => %{
                 "available_cents" => 12,
                 "lots" => [
                   %{
                     "source_operation_id" => "convert-chunk-order",
                     "remaining_cents" => 12
                   }
                 ]
               }
             } = get_credit("2027-02-05")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 10,
                 "cash_charged_back_cents" => 5,
                 "credit_liability_cents" => 12
               }
             } = get_ledger()
    end
  end

  describe "validation and revision guards" do
    test "resolves groups and both revisions before transfer validation", %{conn: conn} do
      operations = [
        open_operation("open-guard-source", "guard-source", [500]),
        open_operation("open-guard-destination", "guard-destination", [500])
      ]

      assert %{"results" => [_, _]} = conn |> post_batch(operations) |> json_response(200)

      attempts = [
        transfer_operation("missing-source", "missing", "guard-destination", 1),
        transfer_operation("missing-destination", "guard-source", "missing", 1),
        transfer_operation("stale-source", "guard-source", "guard-destination", 0)
        |> Map.put("expected_revision", 9),
        transfer_operation("stale-destination", "guard-source", "guard-destination", 0)
        |> Map.put("destination_expected_revision", 9),
        transfer_operation("same-group", "guard-source", "guard-source", 1)
      ]

      assert %{"results" => results} =
               build_conn() |> post_batch(attempts) |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "group_not_found",
               "group_not_found",
               "stale_revision",
               "stale_revision",
               "invalid_transfer"
             ]

      assert Enum.at(results, 0)["group_id"] == "missing"
      assert Enum.at(results, 1)["group_id"] == "missing"

      assert Map.take(Enum.at(results, 2), ["group_id", "expected_revision", "actual_revision"]) ==
               %{"group_id" => "guard-source", "expected_revision" => 9, "actual_revision" => 1}

      assert Map.take(Enum.at(results, 3), ["group_id", "expected_revision", "actual_revision"]) ==
               %{
                 "group_id" => "guard-destination",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
    end

    test "uses the transfer rejection taxonomy without changing either group", %{conn: conn} do
      operations = [
        open_operation("open-tax-source", "tax-source", [500]),
        payment_operation("pay-tax-source", "tax-source", 50),
        open_operation("open-tax-destination", "tax-destination", [200]),
        open_operation("open-other-guest", "other-guest", [500], "somebody-else"),
        open_operation("open-inactive", "inactive", [500]),
        %{
          "operation_id" => "cancel-inactive",
          "type" => "cancel_group",
          "occurred_on" => "2027-02-01",
          "group_id" => "inactive"
        }
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      attempts = [
        transfer_operation("different-guests", "tax-source", "other-guest", 1),
        transfer_operation("inactive-group", "tax-source", "inactive", 1),
        transfer_operation("bad-amount", "tax-source", "tax-destination", 0),
        transfer_operation("too-much-source", "tax-source", "tax-destination", 51),
        transfer_operation("too-much-destination", "tax-source", "tax-destination", 50)
      ]

      assert %{"results" => results} =
               build_conn() |> post_batch(attempts) |> json_response(200)

      assert Enum.map(results, & &1["code"]) == [
               "invalid_transfer",
               "group_not_active",
               "invalid_amount",
               "transfer_exceeds_held_funding",
               "transfer_exceeds_outstanding"
             ]

      assert Enum.at(results, 1)["group_id"] == "inactive"
      assert get_group("tax-source") |> get_in(["data", "revision"]) == 2
      assert get_group("tax-destination") |> get_in(["data", "revision"]) == 1
    end
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp get_group(group_id),
    do: build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)

  defp get_payment(operation_id),
    do: build_conn() |> get("/api/v1/payments/#{operation_id}") |> json_response(200)

  defp get_credit(on),
    do:
      build_conn()
      |> get("/api/v1/guests/transfer-guest/credit?on=#{on}")
      |> json_response(200)

  defp get_ledger,
    do: build_conn() |> get("/api/v1/ledger?on=2027-02-04") |> json_response(200)

  defp open_operation(operation_id, group_id, rates, guest_id \\ "transfer-guest") do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-12-01",
      "departure_on" => "2027-12-02",
      "rate_plan" => "flexible",
      "rooms" =>
        rates
        |> Enum.with_index()
        |> Enum.map(fn {rate, index} ->
          %{"room_id" => "room-#{index}", "nightly_rate_cents" => rate}
        end)
    }
  end

  defp payment_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp credit_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-02-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer_operation(operation_id, source, destination, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2027-02-03",
      "source_group_id" => source,
      "destination_group_id" => destination,
      "amount_cents" => amount
    }
  end

  defp credit_lot_operations do
    [
      open_operation("open-credit-bank", "credit-bank", [500]),
      payment_operation("pay-credit-bank", "credit-bank", 100),
      %{
        "operation_id" => "make-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-02-01",
        "group_id" => "credit-bank",
        "refund_method" => "hotel_credit"
      }
    ]
  end
end
