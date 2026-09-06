defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp open(group_id, guest_id \\ "transfer-guest", rooms \\ ["a", "b"]) do
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
      "rooms" => Enum.map(rooms, &%{"room_id" => &1, "nightly_rate_cents" => 10_000})
    }
  end

  defp pay(id, group_id, amount) do
    %{
      "operation_id" => id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer(id, source, destination, amount, extra \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-04",
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      },
      extra
    )
  end

  defp submit(operations) do
    build_conn()
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp group(id) do
    get(build_conn(), "/api/v1/groups/#{id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger do
    get(build_conn(), ~p"/api/v1/ledger?on=2027-01-04")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "moves newest funding across kinds, preserves provenance, and is durably idempotent" do
    submit([
      open("credit-maker", "transfer-guest", ["credit"]),
      pay("credit-cash", "credit-maker", 1_000),
      %{
        "operation_id" => "issue-transfer-credit",
        "type" => "cancel_group",
        "occurred_on" => "2027-10-01",
        "group_id" => "credit-maker",
        "refund_method" => "hotel_credit"
      },
      open("mixed-source"),
      pay("mixed-payment", "mixed-source", 1_500),
      %{
        "operation_id" => "apply-transfer-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-10-02",
        "group_id" => "mixed-source",
        "amount_cents" => 1_000
      },
      open("mixed-destination")
    ])

    operation =
      transfer("mixed-transfer", "mixed-source", "mixed-destination", 1_200, %{
        "expected_revision" => 3,
        "destination_expected_revision" => 1
      })

    before_ledger = ledger()
    [result] = submit([operation])

    assert result == %{
             "operation_id" => "mixed-transfer",
             "status" => "applied",
             "source_group_id" => "mixed-source",
             "destination_group_id" => "mixed-destination",
             "amount_cents" => 1_200,
             "source_outstanding_deposit_cents" => 2_700,
             "destination_outstanding_deposit_cents" => 2_800,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    assert submit([operation]) == [result]
    assert ledger() == before_ledger

    assert %{"cash_paid_cents" => 1_300, "credit_paid_cents" => 0} = group("mixed-source")

    assert %{"cash_paid_cents" => 200, "credit_paid_cents" => 1_000} =
             group("mixed-destination")

    statement =
      get(build_conn(), ~p"/api/v1/payments/mixed-payment")
      |> json_response(200)
      |> Map.fetch!("data")

    assert statement["held_by_group"] == [
             %{"group_id" => "mixed-destination", "amount_cents" => 200},
             %{"group_id" => "mixed-source", "amount_cents" => 1_300}
           ]

    submit([
      %{
        "operation_id" => "cancel-credit-destination",
        "type" => "cancel_group",
        "occurred_on" => "2027-10-03",
        "group_id" => "mixed-destination"
      }
    ])

    credit =
      get(build_conn(), ~p"/api/v1/guests/transfer-guest/credit?on=2027-10-03")
      |> json_response(200)
      |> Map.fetch!("data")

    assert credit["available_cents"] == 1_100
  end

  test "validates existence and both revisions before transfer domain rules" do
    submit([open("guard-source"), open("guard-destination")])

    assert [%{"code" => "group_not_found", "group_id" => "missing-source"}] =
             submit([transfer("missing-source-op", "missing-source", "missing-destination", 1)])

    assert [%{"code" => "group_not_found", "group_id" => "missing-destination"}] =
             submit([
               transfer("missing-destination-op", "guard-source", "missing-destination", 1)
             ])

    assert [stale] =
             submit([
               transfer("stale-destination", "guard-source", "guard-source", -1, %{
                 "expected_revision" => 1,
                 "destination_expected_revision" => 9
               })
             ])

    assert stale["code"] == "stale_revision"
    assert stale["group_id"] == "guard-source"
    assert stale["expected_revision"] == 9
    assert stale["actual_revision"] == 1

    submit([open("other-guest", "someone-else")])

    assert [%{"code" => "invalid_transfer"}] =
             submit([transfer("different-guests", "guard-source", "other-guest", 1)])
  end

  test "reduction follows transferred cash and increments every changed group revision" do
    submit([
      open("reduce-source"),
      pay("transferred-payment", "reduce-source", 3_000),
      open("reduce-destination"),
      transfer("transfer-before-reduce", "reduce-source", "reduce-destination", 1_000)
    ])

    [result] =
      submit([
        %{
          "operation_id" => "reduce-after-transfer",
          "type" => "reduce_cash_payment",
          "occurred_on" => "2027-01-05",
          "payment_operation_id" => "transferred-payment",
          "amount_cents" => 1_500,
          "expected_revision" => 3
        }
      ])

    assert result["revision"] == 4
    assert result["outstanding_deposit_cents"] == 2_500
    assert group("reduce-source")["revision"] == 4
    assert group("reduce-destination")["revision"] == 3
    assert group("reduce-destination")["outstanding_deposit_cents"] == 4_000

    statement =
      get(build_conn(), ~p"/api/v1/payments/transferred-payment")
      |> json_response(200)
      |> Map.fetch!("data")

    assert statement["held_by_group"] == [
             %{"group_id" => "reduce-source", "amount_cents" => 1_500}
           ]
  end

  test "chargeback reclassifies cash settled after transfer and revises both groups" do
    submit([
      open("charge-source", "charge-guest", ["source"]),
      pay("charge-transfer-payment", "charge-source", 2_000),
      open("charge-destination", "charge-guest", ["destination"]),
      transfer("transfer-before-settlement", "charge-source", "charge-destination", 2_000),
      %{
        "operation_id" => "settle-transferred-payment",
        "type" => "cancel_group",
        "occurred_on" => "2027-10-01",
        "group_id" => "charge-destination"
      }
    ])

    assert ledger()["cash_refunded_cents"] == 2_000

    [result] =
      submit([
        %{
          "operation_id" => "chargeback-after-transfer",
          "type" => "charge_back_payment",
          "occurred_on" => "2027-10-02",
          "payment_operation_id" => "charge-transfer-payment",
          "expected_revision" => 3
        }
      ])

    assert result["revision"] == 4
    assert group("charge-source")["revision"] == 4
    assert group("charge-destination")["revision"] == 4
    assert ledger()["cash_refunded_cents"] == 0
    assert ledger()["cash_charged_back_cents"] == 2_000

    statement =
      get(build_conn(), ~p"/api/v1/payments/charge-transfer-payment")
      |> json_response(200)
      |> Map.fetch!("data")

    assert statement["held_by_group"] == []
  end
end
