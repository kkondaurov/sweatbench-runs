defmodule GroupStayWeb.PaymentControllerTest do
  @moduledoc """
  `GET /api/v1/payments/:payment_operation_id` reconciles one durably
  recorded, applied cash payment.
  """
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{operations: operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => next_id(),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
      },
      overrides
    )
  end

  defp next_id, do: "op-#{System.unique_integer([:positive])}"
  defp uniq(suffix), do: "group-#{suffix}-#{System.unique_integer([:positive])}"

  test "returns the full lifecycle disposition of a payment", %{conn: conn} do
    group_id = uniq("lifecycle")

    [_, pay] =
      submit(conn, [
        open_op(group_id),
        %{
          "operation_id" => next_id(),
          "type" => "record_cash_payment",
          "group_id" => group_id,
          "amount_cents" => 5000
        }
      ])

    # Reducing 1000 leaves 4000 held.
    reduce_op = %{
      "operation_id" => next_id(),
      "type" => "reduce_cash_payment",
      "payment_operation_id" => pay["operation_id"],
      "amount_cents" => 1000
    }

    assert %{"status" => "applied"} = hd(submit(conn, [reduce_op]))

    response =
      conn
      |> get(~p"/api/v1/payments/#{pay["operation_id"]}")
      |> json_response(200)

    assert %{
             "data" => %{
               "payment_operation_id" => _,
               "original_group_id" => ^group_id,
               "recorded_cents" => 5000,
               "held_cents" => 4000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             }
           } = response

    # Refundable cancellation settles the remaining held cash.
    submit(conn, [
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      }
    ])

    settled =
      conn
      |> get(~p"/api/v1/payments/#{pay["operation_id"]}")
      |> json_response(200)

    assert %{
             "data" => %{
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "refunded_cents" => 4000,
               "reduced_cents" => 1000,
               "charged_back_cents" => 0
             }
           } = settled
  end

  test "tracks charged-back cash for a cancelled payment", %{conn: conn} do
    group_id = uniq("chargeback")

    [_, pay, _cancel] =
      submit(conn, [
        open_op(group_id),
        %{
          "operation_id" => next_id(),
          "type" => "record_cash_payment",
          "group_id" => group_id,
          "amount_cents" => 5000
        },
        %{
          "operation_id" => next_id(),
          "type" => "cancel_group",
          "occurred_on" => "2026-11-27",
          "group_id" => group_id
        }
      ])

    submit(conn, [
      %{
        "operation_id" => next_id(),
        "type" => "charge_back_payment",
        "payment_operation_id" => pay["operation_id"]
      }
    ])

    response =
      conn
      |> get(~p"/api/v1/payments/#{pay["operation_id"]}")
      |> json_response(200)

    assert %{
             "data" => %{
               "recorded_cents" => 5000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 5000
             }
           } = response
  end

  test "reports converted cash while it remains converted", %{conn: conn} do
    group_id = uniq("converted")

    [_, pay] =
      submit(conn, [
        open_op(group_id),
        %{
          "operation_id" => next_id(),
          "type" => "record_cash_payment",
          "group_id" => group_id,
          "amount_cents" => 3000
        }
      ])

    submit(conn, [
      %{
        "operation_id" => next_id(),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ])

    response =
      conn
      |> get(~p"/api/v1/payments/#{pay["operation_id"]}")
      |> json_response(200)

    assert %{
             "data" => %{
               "recorded_cents" => 3000,
               "held_cents" => 0,
               "converted_to_credit_cents" => 3000
             }
           } = response
  end

  test "returns 404 operation_not_found when no durable record exists", %{conn: conn} do
    response =
      conn
      |> get(~p"/api/v1/payments/op-missing")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "returns 422 payment_not_reconcilable for recorded non-payments or rejected payments", %{
    conn: conn
  } do
    group_id = uniq("not-reconcilable")

    [open, rejected] =
      submit(conn, [
        open_op(group_id),
        %{
          "operation_id" => next_id(),
          "type" => "record_cash_payment",
          "group_id" => group_id,
          "amount_cents" => 0
        }
      ])

    assert %{"status" => "rejected"} = rejected

    for path <- [open["operation_id"], rejected["operation_id"]] do
      response =
        conn
        |> get(~p"/api/v1/payments/#{path}")
        |> json_response(422)

      assert response == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end

  test "payments recorded without an identifier cannot be read", %{conn: conn} do
    group_id = uniq("legacy")

    [_, pay] =
      submit(conn, [
        open_op(group_id),
        %{
          "type" => "record_cash_payment",
          "group_id" => group_id,
          "amount_cents" => 500
        }
        |> Map.delete("operation_id")
      ])

    assert %{"status" => "applied", "operation_id" => nil} = pay

    response =
      conn
      |> get(~p"/api/v1/payments/no-id")
      |> json_response(404)

    assert response == %{"error" => %{"code" => "operation_not_found"}}
  end

  test "a reading never changes the disposition", %{conn: conn} do
    group_id = uniq("read-stable")

    [_, pay] =
      submit(conn, [
        open_op(group_id),
        %{
          "operation_id" => next_id(),
          "type" => "record_cash_payment",
          "group_id" => group_id,
          "amount_cents" => 900
        }
      ])

    first =
      conn
      |> get(~p"/api/v1/payments/#{pay["operation_id"]}")
      |> json_response(200)

    again =
      conn
      |> get(~p"/api/v1/payments/#{pay["operation_id"]}")
      |> json_response(200)

    assert first == again
  end
end
