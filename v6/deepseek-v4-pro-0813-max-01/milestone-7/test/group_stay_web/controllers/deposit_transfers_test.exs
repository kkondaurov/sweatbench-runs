defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp submit(conn, op) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => [op]})
    json = Jason.decode!(resp.resp_body)
    assert resp.status == 200, "unexpected batch failure: #{inspect(json)}"
    hd(json["results"])
  end

  defp submit_all(conn, operations) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    Jason.decode!(resp.resp_body)["results"]
  end

  defp open(conn, group_id, opts \\ []) do
    arrival_on = Keyword.get(opts, :arrival_on, "2026-12-10")

    rooms =
      Keyword.get(
        opts,
        :rooms,
        for(id <- ~w(room-a room-b), do: %{"room_id" => id, "nightly_rate_cents" => 10_000})
      )

    submit(conn, %{
      "operation_id" => Keyword.get(opts, :operation_id, "open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :booked_on, "2026-10-03"),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => "ams-canal",
      "arrival_on" => arrival_on,
      "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" => rooms
    })
  end

  defp pay(conn, group_id, amount_cents, operation_id, opts \\ []) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-04"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp apply_credit(conn, group_id, amount_cents, occurred_on, operation_id) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    })
  end

  defp cancel_group(conn, group_id, occurred_on, operation_id, opts \\ []) do
    op = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }

    op =
      case Keyword.fetch(opts, :refund_method) do
        {:ok, method} -> Map.put(op, "refund_method", method)
        :error -> op
      end

    submit(conn, op)
  end

  defp transfer(
         conn,
         source_group_id,
         destination_group_id,
         amount_cents,
         operation_id,
         opts \\ []
       ) do
    op = %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }

    op =
      case Keyword.fetch(opts, :expected_revision) do
        {:ok, revision} -> Map.put(op, "expected_revision", revision)
        :error -> op
      end

    op =
      case Keyword.fetch(opts, :destination_expected_revision) do
        {:ok, revision} -> Map.put(op, "destination_expected_revision", revision)
        :error -> op
      end

    submit(conn, op)
  end

  defp reduce(conn, payment_operation_id, amount_cents, operation_id) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    })
  end

  defp charge_back(conn, payment_operation_id, operation_id) do
    submit(conn, %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "payment_operation_id" => payment_operation_id
    })
  end

  defp group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end

  defp payment(conn, payment_operation_id) do
    resp = get(conn, "/api/v1/payments/#{payment_operation_id}")
    {resp, Jason.decode!(resp.resp_body)}
  end

  defp room(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  describe "transfer_deposit" do
    test "moves held cash and credit in reverse allocation order preserving provenance", %{
      conn: conn
    } do
      guest_id = "guest-xfer"

      open(conn, "xfer-src", guest_id: guest_id)
      pay(conn, "xfer-src", 5_000, "xfer-pay")

      open(conn, "xfer-cr",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "xfer-cr", 5_000, "xfer-cr-pay")
      cancel_group(conn, "xfer-cr", "2026-11-01", "xfer-cr-cancel", refund_method: "hotel_credit")

      apply_credit(conn, "xfer-src", 3_000, "2026-11-10", "xfer-apply")

      open(conn, "xfer-dst",
        guest_id: guest_id,
        rooms:
          for(
            id <- ~w(room-a room-b room-c),
            do: %{"room_id" => id, "nightly_rate_cents" => 10_000}
          )
      )

      # Source holds cash (room-a: 5000 + credit 1000) and credit
      # (room-b: 2000). Reverse allocation order draws room-b's credit, then
      # room-a's credit, then room-a's cash.
      result = transfer(conn, "xfer-src", "xfer-dst", 8_000, "xfer-t")

      assert result == %{
               "operation_id" => "xfer-t",
               "status" => "applied",
               "source_group_id" => "xfer-src",
               "destination_group_id" => "xfer-dst",
               "amount_cents" => 8_000,
               "source_outstanding_deposit_cents" => 12_000,
               "destination_outstanding_deposit_cents" => 10_000,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      src = group(conn, "xfer-src")
      assert src["revision"] == 4
      assert src["cash_paid_cents"] == 0
      assert src["credit_paid_cents"] == 0
      assert src["outstanding_deposit_cents"] == 12_000

      dst = group(conn, "xfer-dst")
      assert dst["revision"] == 2
      assert dst["cash_paid_cents"] == 5_000
      assert dst["credit_paid_cents"] == 3_000
      assert dst["outstanding_deposit_cents"] == 10_000

      # The destination fills in original room order, one drawn unit at a time:
      # credit lands first on room-a, then the drawn cash finishes room-a and
      # spills into room-b.
      assert room(dst, "room-a")["cash_paid_cents"] == 3_000
      assert room(dst, "room-a")["credit_paid_cents"] == 3_000
      assert room(dst, "room-b")["cash_paid_cents"] == 2_000
      assert room(dst, "room-c")["cash_paid_cents"] == 0

      # The transfer settles nothing and changes no ledger total.
      assert ledger(conn) == %{
               "cash_held_cents" => 5_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 5_500,
               "credit_shortfall_cents" => 0
             }

      # The cash payment's statement now tracks its held balance per group.
      {resp, body} = payment(conn, "xfer-pay")
      assert resp.status == 200

      assert body["data"] == %{
               "payment_operation_id" => "xfer-pay",
               "original_group_id" => "xfer-src",
               "recorded_cents" => 5_000,
               "held_cents" => 5_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "xfer-dst", "amount_cents" => 5_000}
               ]
             }

      # A refundable cancellation of the destination refunds the transferred
      # cash and restores the transferred credit to its original lot.
      cancelled = cancel_group(conn, "xfer-dst", "2026-11-01", "xfer-dst-cancel")

      assert cancelled["refunded_cents"] == 5_000
      assert cancelled["retained_cents"] == 0
      assert cancelled["credit_issued_cents"] == 0

      assert credit(conn, guest_id) == %{
               "guest_id" => guest_id,
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "xfer-cr-cancel",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_refunded_cents"] == 5_000
      assert ledger(conn)["credit_liability_cents"] == 5_500

      {_resp, body} = payment(conn, "xfer-pay")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["refunded_cents"] == 5_000
      assert body["data"]["held_by_group"] == []
    end

    test "statement gains held_by_group on first participation and empties as held cash leaves",
         %{conn: conn} do
      open(conn, "hold-a")
      pay(conn, "hold-a", 10_000, "hold-pay")

      open(conn, "hold-b", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])
      open(conn, "hold-c", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      {_resp, body} = payment(conn, "hold-pay")

      # Payments that never participated in a transfer keep the earlier shape.
      refute Map.has_key?(body["data"], "held_by_group")

      transfer(conn, "hold-a", "hold-b", 5_000, "hold-t1")

      {_resp, body} = payment(conn, "hold-pay")

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "hold-a", "amount_cents" => 5_000},
               %{"group_id" => "hold-b", "amount_cents" => 5_000}
             ]

      transfer(conn, "hold-a", "hold-c", 5_000, "hold-t2")

      {_resp, body} = payment(conn, "hold-pay")

      assert Enum.sum(Enum.map(body["data"]["held_by_group"], & &1["amount_cents"])) ==
               body["data"]["held_cents"]

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "hold-b", "amount_cents" => 5_000},
               %{"group_id" => "hold-c", "amount_cents" => 5_000}
             ]

      assert reduce(conn, "hold-pay", 10_000, "hold-red")["status"] == "applied"

      {_resp, body} = payment(conn, "hold-pay")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["held_by_group"] == []
    end

    test "validates groups, guests, amounts, and capacity", %{conn: conn} do
      open(conn, "v-src")
      pay(conn, "v-src", 2_000, "v-pay")
      open(conn, "v-dst")
      open(conn, "v-other", guest_id: "guest-99")
      open(conn, "v-dst2")

      assert transfer(conn, "v-src", "v-src", 100, "v-same")["code"] == "invalid_transfer"
      assert transfer(conn, "v-src", "v-other", 100, "v-guest")["code"] == "invalid_transfer"

      # A cancelled destination is inactive.
      cancel_group(conn, "v-dst", "2026-11-01", "v-cancel-dst")

      assert transfer(conn, "v-src", "v-dst", 100, "v-inactive-dst") == %{
               "operation_id" => "v-inactive-dst",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "v-dst"
             }

      # A cancelled source is inactive.
      open(conn, "v-src2")
      pay(conn, "v-src2", 500, "v-pay2")
      cancel_group(conn, "v-src2", "2026-11-01", "v-cancel-src2")

      assert transfer(conn, "v-src2", "v-src", 100, "v-inactive-src")["code"] ==
               "group_not_active"

      assert transfer(conn, "v-src2", "v-src", 100, "v-inactive-src")["group_id"] == "v-src2"

      # Unusable amounts.
      assert transfer(conn, "v-src", "v-dst2", 0, "v-zero")["code"] == "invalid_amount"
      assert transfer(conn, "v-src", "v-dst2", -5, "v-neg")["code"] == "invalid_amount"
      assert transfer(conn, "v-src", "v-dst2", 100.5, "v-float")["code"] == "invalid_amount"

      assert submit(conn, %{
               "operation_id" => "v-missing-amount",
               "type" => "transfer_deposit",
               "source_group_id" => "v-src",
               "destination_group_id" => "v-dst2"
             })["code"] == "invalid_operation"

      assert submit(conn, %{
               "operation_id" => "v-missing-dst",
               "type" => "transfer_deposit",
               "source_group_id" => "v-src",
               "amount_cents" => 100
             })["code"] == "invalid_operation"

      # Exceeding held funding.
      assert transfer(conn, "v-src", "v-dst2", 2_001, "v-held")["code"] ==
               "transfer_exceeds_held_funding"

      open(conn, "v-empty")

      assert transfer(conn, "v-empty", "v-dst2", 100, "v-empty-held")["code"] ==
               "transfer_exceeds_held_funding"

      # Exceeding the destination's outstanding deposit.
      pay(conn, "v-dst2", 12_000, "v-full-pay")

      assert transfer(conn, "v-src", "v-dst2", 100, "v-outstanding")["code"] ==
               "transfer_exceeds_outstanding"

      # Existence is resolved source first, then destination.
      assert transfer(conn, "v-ghost", "v-dst2", 100, "v-nf-src") == %{
               "operation_id" => "v-nf-src",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "v-ghost"
             }

      assert transfer(conn, "v-src", "v-ghost", 100, "v-nf-dst") == %{
               "operation_id" => "v-nf-dst",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "v-ghost"
             }

      # None of the rejections changed state.
      assert group(conn, "v-src")["revision"] == 2
      assert group(conn, "v-src")["cash_paid_cents"] == 2_000
      assert ledger(conn)["cash_held_cents"] == 14_000
    end

    test "guards the source revision and then the destination revision", %{conn: conn} do
      open(conn, "r-src")
      open(conn, "r-dst")
      pay(conn, "r-src", 1_000, "r-pay")

      # Both groups stale: the source's guard fires first.
      assert transfer(conn, "r-src", "r-dst", 100, "r-both",
               expected_revision: 1,
               destination_expected_revision: 1
             ) == %{
               "operation_id" => "r-both",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "r-src",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # Only the destination stale: reported with the destination's values.
      pay(conn, "r-dst", 100, "r-dst-pay")

      assert transfer(conn, "r-src", "r-dst", 100, "r-dst-stale",
               expected_revision: 2,
               destination_expected_revision: 1
             ) == %{
               "operation_id" => "r-dst-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "r-dst",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert group(conn, "r-src")["revision"] == 2
      assert group(conn, "r-dst")["revision"] == 2

      result = transfer(conn, "r-src", "r-dst", 100, "r-ok", expected_revision: 2)

      assert result["status"] == "applied"
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 3
    end

    test "is durably idempotent and visible to later operations in the same batch", %{conn: conn} do
      open(conn, "i-src")
      pay(conn, "i-src", 3_000, "i-pay")
      open(conn, "i-dst", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      op = %{
        "operation_id" => "i-xfer",
        "type" => "transfer_deposit",
        "source_group_id" => "i-src",
        "destination_group_id" => "i-dst",
        "amount_cents" => 3_000
      }

      first = submit(conn, op)
      assert first["status"] == "applied"

      assert submit(conn, op) == first
      assert group(conn, "i-src")["revision"] == 3
      assert group(conn, "i-dst")["revision"] == 2
      assert group(conn, "i-src")["cash_paid_cents"] == 0
      assert group(conn, "i-dst")["cash_paid_cents"] == 3_000

      assert conn |> get("/api/v1/operations/i-xfer") |> json_response(200) |> Map.fetch!("data") ==
               first

      # A batch can move funding twice: the second transfer observes the
      # first, including the revised source revision.
      open(conn, "mv-src", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])
      pay(conn, "mv-src", 6_000, "mv-pay")

      open(conn, "mv-a", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])
      open(conn, "mv-b", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      results =
        submit_all(conn, [
          %{
            "operation_id" => "mv-t1",
            "type" => "transfer_deposit",
            "source_group_id" => "mv-src",
            "destination_group_id" => "mv-a",
            "amount_cents" => 4_000,
            "expected_revision" => 2
          },
          %{
            "operation_id" => "mv-t2",
            "type" => "transfer_deposit",
            "source_group_id" => "mv-src",
            "destination_group_id" => "mv-b",
            "amount_cents" => 2_000,
            "expected_revision" => 3
          }
        ])

      assert Enum.map(results, & &1["status"]) == ["applied", "applied"]

      assert group(conn, "mv-src")["revision"] == 4
      assert group(conn, "mv-a")["cash_paid_cents"] == 4_000
      assert group(conn, "mv-b")["cash_paid_cents"] == 2_000
      assert group(conn, "mv-src")["outstanding_deposit_cents"] == 6_000
    end
  end

  describe "reductions and chargebacks across groups" do
    test "reductions follow a payment's allocations across groups", %{conn: conn} do
      open(conn, "red-src")
      pay(conn, "red-src", 10_000, "red-pay")

      open(conn, "red-dst", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      transfer(conn, "red-src", "red-dst", 6_000, "red-t")

      # The destination holds the newest allocations, so the reduction hollows
      # it first, then reaches back into the source's remaining room.
      result = reduce(conn, "red-pay", 7_000, "red-1")

      assert result == %{
               "operation_id" => "red-1",
               "status" => "applied",
               "payment_operation_id" => "red-pay",
               "group_id" => "red-src",
               "amount_cents" => 7_000,
               "outstanding_deposit_cents" => 9_000,
               "revision" => 4
             }

      src = group(conn, "red-src")
      assert src["revision"] == 4
      assert src["cash_paid_cents"] == 3_000
      assert src["outstanding_deposit_cents"] == 9_000

      dst = group(conn, "red-dst")
      assert dst["revision"] == 3
      assert dst["cash_paid_cents"] == 0
      assert dst["outstanding_deposit_cents"] == 6_000

      assert ledger(conn)["cash_held_cents"] == 3_000
      assert ledger(conn)["cash_reduced_cents"] == 7_000

      {_resp, body} = payment(conn, "red-pay")
      assert body["data"]["held_cents"] == 3_000
      assert body["data"]["reduced_cents"] == 7_000

      assert body["data"]["held_by_group"] == [
               %{"group_id" => "red-src", "amount_cents" => 3_000}
             ]
    end

    test "subsequent reductions drain the remaining held cash wherever it lives", %{conn: conn} do
      open(conn, "red2-src", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])
      pay(conn, "red2-src", 5_000, "red2-pay")

      open(conn, "red2-dst", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      transfer(conn, "red2-src", "red2-dst", 5_000, "red2-t")

      assert reduce(conn, "red2-pay", 2_000, "red2-1")["status"] == "applied"

      assert group(conn, "red2-dst")["revision"] == 3
      assert group(conn, "red2-dst")["cash_paid_cents"] == 3_000

      result = reduce(conn, "red2-pay", 3_000, "red2-2")
      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 6_000

      assert group(conn, "red2-dst")["revision"] == 4
      assert group(conn, "red2-dst")["cash_paid_cents"] == 0

      assert reduce(conn, "red2-pay", 1, "red2-3")["code"] == "payment_not_reducible"
      assert group(conn, "red2-dst")["revision"] == 4
    end

    test "chargebacks reverse held cash across groups and bump every touched group", %{
      conn: conn
    } do
      open(conn, "cb-src")
      pay(conn, "cb-src", 10_000, "cb-pay")

      open(conn, "cb-dst", rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}])

      transfer(conn, "cb-src", "cb-dst", 4_000, "cb-t")

      result = charge_back(conn, "cb-pay", "cb-op")

      assert result == %{
               "operation_id" => "cb-op",
               "status" => "applied",
               "payment_operation_id" => "cb-pay",
               "group_id" => "cb-src",
               "charged_back_cents" => 10_000,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 4
             }

      assert group(conn, "cb-src")["cash_paid_cents"] == 0
      assert group(conn, "cb-src")["revision"] == 4

      assert group(conn, "cb-dst")["cash_paid_cents"] == 0
      assert group(conn, "cb-dst")["revision"] == 3

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 10_000

      {_resp, body} = payment(conn, "cb-pay")
      assert body["data"]["held_cents"] == 0
      assert body["data"]["charged_back_cents"] == 10_000
      assert body["data"]["held_by_group"] == []
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash earns the standard bonus when the destination converts it", %{
      conn: conn
    } do
      guest_id = "guest-bonus-xfer"

      open(conn, "bx-src", guest_id: guest_id)
      pay(conn, "bx-src", 5_000, "bx-pay")

      open(conn, "bx-dst",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      transfer(conn, "bx-src", "bx-dst", 5_000, "bx-t")

      result =
        cancel_group(conn, "bx-dst", "2026-11-01", "bx-cancel", refund_method: "hotel_credit")

      assert result["refunded_cents"] == 0
      assert result["credit_issued_cents"] == 5_500

      assert credit(conn, guest_id)["available_cents"] == 5_500
      assert ledger(conn)["cash_converted_to_credit_cents"] == 5_000

      {_resp, body} = payment(conn, "bx-pay")
      assert body["data"]["converted_to_credit_cents"] == 5_000
      assert body["data"]["held_by_group"] == []

      # A chargeback of the original payment revokes the entitlement the
      # destination's conversion created.
      charge_back(conn, "bx-pay", "bx-op")

      assert credit(conn, guest_id)["available_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
    end

    test "transferred cash settles under the destination group's policy", %{conn: conn} do
      open(conn, "pol-src")
      pay(conn, "pol-src", 2_000, "pol-pay")

      open(conn, "pol-dst",
        rate_plan: "advance_purchase",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      transfer(conn, "pol-src", "pol-dst", 2_000, "pol-t")

      # The advance-purchase destination is non-refundable, so cancelling it
      # retains the cash transferred there.
      result = cancel_group(conn, "pol-dst", "2026-11-01", "pol-cancel")

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 2_000

      assert group(conn, "pol-dst")["status"] == "cancelled"
      assert group(conn, "pol-src")["status"] == "active"
      assert group(conn, "pol-src")["outstanding_deposit_cents"] == 12_000

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_retained_cents"] == 2_000

      {_resp, body} = payment(conn, "pol-pay")
      assert body["data"]["retained_cents"] == 2_000
      assert body["data"]["held_by_group"] == []
    end

    test "transferred credit returns to its original lot without another bonus", %{conn: conn} do
      guest_id = "guest-restore"

      open(conn, "rest-src",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      pay(conn, "rest-src", 5_000, "rest-pay")
      cancel_group(conn, "rest-src", "2026-11-01", "rest-cancel", refund_method: "hotel_credit")

      open(conn, "rest-a",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      open(conn, "rest-b",
        guest_id: guest_id,
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      )

      apply_credit(conn, "rest-a", 3_000, "2026-11-10", "rest-apply")

      assert credit(conn, guest_id)["available_cents"] == 2_500

      transfer(conn, "rest-a", "rest-b", 1_000, "rest-t")

      assert credit(conn, guest_id)["available_cents"] == 2_500

      # Refundable cancellation of the destination restores the credit to its
      # original lot and expiry, without a second bonus.
      cancel_group(conn, "rest-b", "2026-11-20", "rest-b-cancel")

      assert credit(conn, guest_id) == %{
               "guest_id" => guest_id,
               "available_cents" => 3_500,
               "lots" => [
                 %{
                   "source_operation_id" => "rest-cancel",
                   "remaining_cents" => 3_500,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert group(conn, "rest-a")["credit_paid_cents"] == 2_000

      assert ledger(conn)["credit_liability_cents"] == 5_500
    end
  end
end
