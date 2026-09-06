defmodule GroupStayWeb.PaymentReductionsTest do
  @moduledoc """
  Acceptance tests for the payment-reduction release: reducing recorded cash
  with `reduce_cash_payment`, reversing payments with
  `charge_back_payment`, and reconciling one payment through the payments
  endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @batch_url "/api/v1/partner-batches"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-open"),
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

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_500
      },
      overrides
    )
  end

  defp cancel_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp cancel_rooms_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel-rooms"),
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81",
        "room_ids" => ["room-a"]
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-reduce"),
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-charge"),
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-1"
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp room_view(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp guest_credit(conn, guest_id) do
    conn = get(conn, "/api/v1/guests/#{guest_id}/credit")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp payment_statement!(conn, operation_id) do
    conn = get(conn, "/api/v1/payments/#{operation_id}")
    assert conn.status == 200, "expected 200, got: #{conn.status}"
    %{"data" => data} = json_response(conn, 200)
    data
  end

  # Opens group-81 (room deposits 9000 and 10500) and records one 9500
  # payment under `op-pay-1` (room-a 9000, room-b 500).
  defp funded_group!(conn) do
    open_group!(conn)
    apply_operation!(conn, payment_operation(%{"operation_id" => "op-pay-1"}))
  end

  describe "reducing recorded cash" do
    test "removes held allocations of the payment in reverse fill order", %{conn: conn} do
      funded_group!(conn)

      result = apply_operation!(conn, reduce_operation(%{"amount_cents" => 2_000}))

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "amount_cents" => 2_000,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 3
             }

      group = fetch_group(conn, "group-81")

      # The payment filled room-a first, then room-b; the reduction removes
      # room-b's 500 first and the rest from room-a.
      assert room_view(group, "room-a")["cash_paid_cents"] == 7_500
      assert room_view(group, "room-b")["cash_paid_cents"] == 0

      # The group's outstanding deposit reopens by the amount removed.
      assert group["deposit_paid_cents"] == 7_500
      assert group["outstanding_deposit_cents"] == 12_000

      statement = payment_statement!(conn, "op-pay-1")

      assert statement == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-81",
               "recorded_cents" => 9_500,
               "held_cents" => 7_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 2_000,
               "charged_back_cents" => 0
             }

      assert ledger(conn)["cash_held_cents"] == 7_500
      assert ledger(conn)["cash_reduced_cents"] == 2_000
    end

    test "successive reductions compose against the remaining held cash", %{conn: conn} do
      funded_group!(conn)

      apply_operation!(conn, reduce_operation(%{"amount_cents" => 4_000}))

      result =
        apply_operation!(
          conn,
          reduce_operation(%{"amount_cents" => 5_500})
        )

      # The second reduction removes the complete remaining held portion.
      assert result["amount_cents"] == 5_500
      assert result["outstanding_deposit_cents"] == 19_500

      statement = payment_statement!(conn, "op-pay-1")
      assert statement["held_cents"] == 0
      assert statement["reduced_cents"] == 9_500

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_reduced_cents"] == 9_500
    end

    test "only cash still held on active rooms can be reduced", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 14_000})
      )

      # Settling room-a refunds the 9000 of the payment allocated there.
      apply_operation!(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      result =
        apply_operation!(
          conn,
          reduce_operation(%{"amount_cents" => 5_000})
        )

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 10_500

      statement = payment_statement!(conn, "op-pay-1")

      # 14000 recorded = 9000 refunded + 5000 reduced.
      assert statement["refunded_cents"] == 9_000
      assert statement["reduced_cents"] == 5_000
      assert statement["held_cents"] == 0

      # Settled history never moves through a reduction.
      assert reject_operation!(conn, reduce_operation(%{"amount_cents" => 100}))["code"] ==
               "payment_not_reducible"
    end

    test "rejection codes", %{conn: conn} do
      funded_group!(conn)

      # A non-payment operation target.
      assert reject_operation!(
               conn,
               reduce_operation(%{"payment_operation_id" => result_open_id(conn)})
             )["code"] == "payment_not_reducible"

      # A rejected payment target.
      reject_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-rejected", "amount_cents" => 99_000})
      )

      assert reject_operation!(
               conn,
               reduce_operation(%{"payment_operation_id" => "op-pay-rejected"})
             )["code"] == "payment_not_reducible"

      # An unknown target.
      assert reject_operation!(
               conn,
               reduce_operation(%{"payment_operation_id" => "op-pay-unknown"})
             )["code"] == "operation_not_found"

      # A non-positive or unusable reduction.
      for amount <- [0, -100, "500", 1.5, nil] do
        assert reject_operation!(conn, reduce_operation(%{"amount_cents" => amount}))["code"] ==
                 "invalid_amount",
               "for #{inspect(amount)}"
      end

      # More than the target payment's currently held cash.
      assert reject_operation!(conn, reduce_operation(%{"amount_cents" => 9_501}))["code"] ==
               "reduction_exceeds_held_cash"

      # A fully reduced payment can never accept another reduction.
      apply_operation!(conn, reduce_operation(%{"amount_cents" => 9_500}))

      assert reject_operation!(conn, reduce_operation(%{"amount_cents" => 100}))["code"] ==
               "payment_not_reducible"

      assert fetch_group(conn, "group-81")["revision"] == 3
    end

    test "follows the revision contract against the original payment's group", %{conn: conn} do
      funded_group!(conn)

      result =
        apply_operation!(conn, reduce_operation(%{"expected_revision" => 2}))

      assert result["revision"] == 3

      stale = reduce_operation(%{"expected_revision" => 2, "amount_cents" => 500})
      result = reject_operation!(conn, stale)

      assert result == %{
               "operation_id" => stale["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      assert fetch_group(conn, "group-81")["revision"] == 3
    end

    test "retrying the original payment returns its exact original result without reapplying", %{
      conn: conn
    } do
      funded_group!(conn)

      payment = payment_operation(%{"operation_id" => "op-pay-1"})

      apply_operation!(conn, reduce_operation(%{"amount_cents" => 2_000}))

      conn
      |> post_batch([payment])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} ->
        # The stored result is returned verbatim, describing the group as it
        # was when the payment was first applied.
        assert retried["status"] == "applied"
        assert retried["revision"] == 2
        assert retried["outstanding_deposit_cents"] == 10_000
      end)

      group = fetch_group(conn, "group-81")
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 7_500
      assert ledger(conn)["cash_reduced_cents"] == 2_000
    end

    test "is durably idempotent", %{conn: conn} do
      funded_group!(conn)

      op = reduce_operation(%{"operation_id" => "op-reduce-1", "amount_cents" => 2_000})
      original = apply_operation!(conn, op)

      conn
      |> post_batch([op])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried == original end)

      assert ledger(conn)["cash_reduced_cents"] == 2_000
      assert fetch_group(conn, "group-81")["revision"] == 3
    end
  end

  defp result_open_id(conn) do
    op = open_group_operation(%{"group_id" => "group-other"})
    apply_operation!(conn, op)
    op["operation_id"]
  end

  describe "charging back a payment" do
    # Simulates a group funded and cancelled with hotel credit before room
    # accounting existed: the group, payment record, cancellation, and lot
    # are durable, but nothing has been brought forward yet.
    defp insert_pre_accounting_converted_group!(spend_cents) do
      Repo.insert!(%Group{
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "cancelled",
        revision: 3,
        lodging_total_cents: 97_500,
        deposit_due_cents: 19_500,
        deposit_paid_cents: 5_000,
        refunded_cents: 0,
        retained_cents: 0,
        cash_converted_cents: 5_000
      })

      Repo.insert!(%Room{
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        position: 0,
        status: "active",
        group_id: Repo.get_by!(Group, group_id: "group-81").id
      })

      Repo.insert!(%Operation{
        operation_id: "op-pay-1",
        type: "record_cash_payment",
        payload: "{}",
        result:
          Jason.encode!(%{
            "operation_id" => "op-pay-1",
            "status" => "applied",
            "group_id" => "group-81",
            "amount_cents" => 5_000,
            "outstanding_deposit_cents" => 14_500,
            "revision" => 2
          })
      })

      Repo.insert!(%Operation{
        operation_id: "op-cancel-old",
        type: "cancel_group",
        payload: "{}",
        result:
          Jason.encode!(%{
            "operation_id" => "op-cancel-old",
            "status" => "applied",
            "group_id" => "group-81",
            "refunded_cents" => 0,
            "retained_cents" => 0,
            "credit_issued_cents" => 5_500,
            "revision" => 3
          })
      })

      Repo.insert!(%Lot{
        guest_id: "guest-22",
        source_operation_id: "op-cancel-old",
        remaining_cents: 5_500 - spend_cents,
        expires_on: ~D[2027-11-27]
      })
    end

    test "reverses a conversion recorded before room accounting", %{conn: conn} do
      insert_pre_accounting_converted_group!(0)

      # The statement describes the settled conversion without bringing
      # anything forward.
      statement = payment_statement!(conn, "op-pay-1")

      assert statement["converted_to_credit_cents"] == 5_000
      assert statement["held_cents"] == 0

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result["charged_back_cents"] == 5_000
      assert result["revision"] == 4

      # The entitlement the conversion created is revoked from the lot.
      assert guest_credit(conn, "guest-22")["available_cents"] == 0

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["converted_to_credit_cents"] == 0
      assert statement["charged_back_cents"] == 5_000

      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "claws back an entitlement from an already-spent pre-accounting lot", %{conn: conn} do
      insert_pre_accounting_converted_group!(5_500)

      apply_operation!(conn, charge_back_operation(%{}))

      # The lot was exhausted, so the whole 5500 entitlement is unrecovered
      # clawback; no credit from the lot is applied to an active group, so
      # the current shortfall is zero.
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "reverses held cash on an active group and reopens its deposit", %{conn: conn} do
      funded_group!(conn)

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "payment_operation_id" => "op-pay-1",
               "group_id" => "group-81",
               "charged_back_cents" => 9_500,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 3
             }

      group = fetch_group(conn, "group-81")

      assert group["status"] == "active"
      assert group["deposit_paid_cents"] == 0
      assert group["outstanding_deposit_cents"] == 19_500

      assert room_view(group, "room-a")["cash_paid_cents"] == 0
      assert room_view(group, "room-b")["cash_paid_cents"] == 0

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["held_cents"] == 0
      assert statement["charged_back_cents"] == 9_500

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 9_500
    end

    test "moves refunded and retained portions to charged-back cash", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_500})
      )

      apply_operation!(conn, cancel_group_operation(%{}))

      assert ledger(conn)["cash_refunded_cents"] == 9_500

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result["charged_back_cents"] == 9_500
      assert result["outstanding_deposit_cents"] == 0
      assert result["revision"] == 4

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["refunded_cents"] == 0
      assert statement["charged_back_cents"] == 9_500

      # The historical refund is not reversed, but its ledger classification
      # moves to charged-back cash.
      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 9_500
    end

    test "revokes the credit entitlement a converted payment created", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"refund_method" => "hotel_credit"})
      )

      assert guest_credit(conn, "guest-22")["available_cents"] == 5_500

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result["charged_back_cents"] == 5_000

      # The lot's entitlement was revoked; the liability is gone.
      assert guest_credit(conn, "guest-22")["available_cents"] == 0

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["converted_to_credit_cents"] == 0
      assert statement["charged_back_cents"] == 5_000

      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
      assert ledger(conn)["credit_liability_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
    end

    test "an entitlement that cannot be removed becomes unrecovered clawback", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"refund_method" => "hotel_credit"})
      )

      # Spend the issued credit on another active group of the same guest.
      open_group!(conn, %{
        "group_id" => "group-82",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      apply_operation!(
        conn,
        apply_credit_operation(%{"group_id" => "group-82", "amount_cents" => 5_500})
      )

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result["charged_back_cents"] == 5_000

      # The lot is exhausted; the whole 5500 entitlement is unrecovered, and
      # the shortfall is the credit still applied to the active group.
      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      # Liability still includes the credit applied to the active group.
      assert ledger(conn)["credit_liability_cents"] == 5_500

      assert fetch_group(conn, "group-82")["revision"] == 2
    end

    test "returning credit extinguishes unrecovered clawback before becoming available", %{
      conn: conn
    } do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"refund_method" => "hotel_credit"})
      )

      open_group!(conn, %{
        "group_id" => "group-82",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      # Two applications from the same lot fund the new group.
      apply_operation!(
        conn,
        apply_credit_operation(%{"group_id" => "group-82", "amount_cents" => 3_000})
      )

      apply_operation!(
        conn,
        apply_credit_operation(%{"group_id" => "group-82", "amount_cents" => 2_500})
      )

      apply_operation!(conn, charge_back_operation(%{}))

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      # A refundable cancellation of group-82 returns both applications to
      # the shortfalled lot: together they extinguish the clawback first.
      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-82",
          "occurred_on" => "2027-06-01"
        })
      )

      assert guest_credit(conn, "guest-22")["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "non-refundable settlement reduces the shortfall automatically", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"refund_method" => "hotel_credit"})
      )

      open_group!(conn, %{
        "group_id" => "group-82",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      apply_operation!(
        conn,
        apply_credit_operation(%{"group_id" => "group-82", "amount_cents" => 5_500})
      )

      apply_operation!(conn, charge_back_operation(%{}))

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      # Consuming the credit non-refundably settles it: it is no longer
      # applied to an active group, so the current shortfall drops.
      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-82",
          "occurred_on" => "2027-12-30"
        })
      )

      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "assigns entitlements telescopically when several payments built one lot", %{
      conn: conn
    } do
      open_group!(conn, %{
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100_000}]
      })

      # 20000 due; 4545 + 4545 = 9090 recorded.
      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 4_545})
      )

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 4_545})
      )

      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{"refund_method" => "hotel_credit"})
        )

      # 9090 * 1.1 = 9999, computed once across both payments.
      assert result["credit_issued_cents"] == 9_999

      # Entitlements telescope: op-pay-1 holds with_bonus(4545) = 5000 and
      # op-pay-2 holds 9999 - 5000 = 4999.
      apply_operation!(conn, charge_back_operation(%{"payment_operation_id" => "op-pay-1"}))

      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 4_999

      statement = payment_statement!(conn, "op-pay-1")
      assert statement["charged_back_cents"] == 4_545

      apply_operation!(conn, charge_back_operation(%{"payment_operation_id" => "op-pay-2"}))

      assert guest_credit(conn, "guest-22")["available_cents"] == 0

      statement = payment_statement!(conn, "op-pay-2")
      assert statement["charged_back_cents"] == 4_545

      assert ledger(conn)["cash_charged_back_cents"] == 9_090
    end

    test "reverses all cash except any portion already recorded as reduced", %{conn: conn} do
      funded_group!(conn)

      apply_operation!(conn, reduce_operation(%{"amount_cents" => 2_000}))

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result["charged_back_cents"] == 7_500

      statement = payment_statement!(conn, "op-pay-1")

      # 9500 recorded = 2000 reduced + 7500 charged back.
      assert statement["reduced_cents"] == 2_000
      assert statement["charged_back_cents"] == 7_500
      assert statement["held_cents"] == 0

      assert ledger(conn)["cash_reduced_cents"] == 2_000
      assert ledger(conn)["cash_charged_back_cents"] == 7_500
    end

    test "rejection codes", %{conn: conn} do
      funded_group!(conn)

      # An unknown target.
      assert reject_operation!(
               conn,
               charge_back_operation(%{"payment_operation_id" => "op-pay-unknown"})
             )["code"] == "operation_not_found"

      # A non-payment operation target.
      assert reject_operation!(
               conn,
               charge_back_operation(%{"payment_operation_id" => result_open_id(conn)})
             )["code"] == "payment_not_chargeable"

      # A rejected payment target.
      reject_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-rejected", "amount_cents" => 99_000})
      )

      assert reject_operation!(
               conn,
               charge_back_operation(%{"payment_operation_id" => "op-pay-rejected"})
             )["code"] == "payment_not_chargeable"

      # A payment already charged back.
      apply_operation!(conn, charge_back_operation(%{}))

      assert reject_operation!(conn, charge_back_operation(%{}))["code"] ==
               "payment_not_chargeable"

      # A fully reduced payment.
      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 10_000})
      )

      apply_operation!(
        conn,
        reduce_operation(%{"payment_operation_id" => "op-pay-2", "amount_cents" => 10_000})
      )

      assert reject_operation!(
               conn,
               charge_back_operation(%{"payment_operation_id" => "op-pay-2"})
             )["code"] == "payment_not_chargeable"

      assert fetch_group(conn, "group-81")["revision"] == 5
    end

    test "increments only the payment group's revision, exactly once", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 5_000})
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"refund_method" => "hotel_credit"})
      )

      open_group!(conn, %{
        "group_id" => "group-82",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      apply_operation!(
        conn,
        apply_credit_operation(%{"group_id" => "group-82", "amount_cents" => 5_500})
      )

      # group-82 sits at revision 2 before the chargeback.
      assert fetch_group(conn, "group-82")["revision"] == 2

      apply_operation!(conn, charge_back_operation(%{}))

      assert fetch_group(conn, "group-81")["revision"] == 4
      assert fetch_group(conn, "group-82")["revision"] == 2
    end

    test "follows the revision contract against the original payment's group", %{conn: conn} do
      funded_group!(conn)

      result =
        apply_operation!(conn, charge_back_operation(%{"expected_revision" => 2}))

      assert result["revision"] == 3

      # A stale revision is rejected before the chargeability rules.
      stale = charge_back_operation(%{"expected_revision" => 2})

      result = reject_operation!(conn, stale)

      assert result == %{
               "operation_id" => stale["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      assert fetch_group(conn, "group-81")["revision"] == 3
    end

    test "is durably idempotent", %{conn: conn} do
      funded_group!(conn)

      op = charge_back_operation(%{"operation_id" => "op-charge-1"})
      original = apply_operation!(conn, op)

      conn
      |> post_batch([op])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried == original end)

      assert ledger(conn)["cash_charged_back_cents"] == 9_500
      assert fetch_group(conn, "group-81")["revision"] == 3
    end
  end

  describe "reconciling one payment" do
    test "returns the current disposition of cash from the payment", %{conn: conn} do
      funded_group!(conn)

      apply_operation!(conn, reduce_operation(%{"amount_cents" => 1_000}))

      assert payment_statement!(conn, "op-pay-1") == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-81",
               "recorded_cents" => 9_500,
               "held_cents" => 8_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0
             }
    end

    test "includes every disposition even when zero", %{conn: conn} do
      open_group!(conn)
      apply_operation!(conn, payment_operation(%{"operation_id" => "op-pay-1"}))

      assert payment_statement!(conn, "op-pay-1") == %{
               "payment_operation_id" => "op-pay-1",
               "original_group_id" => "group-81",
               "recorded_cents" => 9_500,
               "held_cents" => 9_500,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }
    end

    test "the dispositions always sum to the recorded amount", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 14_000})
      )

      apply_operation!(conn, cancel_rooms_operation(%{"room_ids" => ["room-a"]}))

      apply_operation!(
        conn,
        reduce_operation(%{"amount_cents" => 2_000})
      )

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["refunded_cents"] == 9_000
      assert statement["reduced_cents"] == 2_000
      assert statement["held_cents"] == 3_000

      assert statement["held_cents"] + statement["refunded_cents"] +
               statement["retained_cents"] + statement["converted_to_credit_cents"] +
               statement["reduced_cents"] + statement["charged_back_cents"] ==
               statement["recorded_cents"]

      # The statement agrees with the ledger view.
      assert ledger(conn)["cash_held_cents"] == 3_000
      assert ledger(conn)["cash_refunded_cents"] == 9_000
      assert ledger(conn)["cash_reduced_cents"] == 2_000
    end

    test "reading a statement never changes state", %{conn: conn} do
      funded_group!(conn)

      before_ledger = ledger(conn)
      before_group = fetch_group(conn, "group-81")

      payment_statement!(conn, "op-pay-1")
      payment_statement!(conn, "op-pay-1")

      assert ledger(conn) == before_ledger

      after_group = fetch_group(conn, "group-81")
      assert after_group == before_group
    end

    test "returns 404 when no durable operation record exists", %{conn: conn} do
      conn = get(conn, "/api/v1/payments/op-never-seen")

      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "returns 422 when the record is not an applied cash payment", %{conn: conn} do
      open_group!(conn, %{"group_id" => "group-open", "operation_id" => "op-open-read"})

      conn = get(conn, "/api/v1/payments/op-open-read")

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      reject_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-rejected", "amount_cents" => 99_000})
      )

      conn = get(conn, "/api/v1/payments/op-pay-rejected")

      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end
end
