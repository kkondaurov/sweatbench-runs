defmodule GroupStayWeb.RoomAccountingTest do
  @moduledoc """
  Product request 04: room-level accounting, settling selected rooms, and
  payment reductions.

  Cash and credit fund active room deposits in the rooms' original order,
  one room's deposit before the next. Group totals describe active rooms
  only. `cancel_rooms` settles selected rooms under the full-cancellation
  rules, `reduce_cash_payment` removes held cash of one durable payment in
  reverse fill order, and `charge_back_payment` reclassifies every
  remaining disposition of a payment, revoking the credit entitlement it
  created.
  """

  use GroupStayWeb.ConnCase, async: true

  alias GroupStay.Repo

  @guest "guest-22"
  @booked_on "2026-10-03"
  @arrival_on "2027-03-10"
  @departure_on "2027-03-13"
  # Two rooms, three nights at 10000: lodging 60000, flexible deposit 6000 each.

  defp open_operation(group_id, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, @guest),
      "property_id" => "ams-canal",
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 10000}
        ])
    }
  end

  defp payment_operation(group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-pay-#{group_id}-#{amount_cents}"),
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(group_id, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-cancel-#{group_id}"),
      "type" => "cancel_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id
    }
    |> maybe_put("refund_method", Keyword.get(opts, :refund_method))
  end

  defp cancel_rooms_operation(group_id, room_ids, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-cancel-rooms-#{group_id}"),
      "type" => "cancel_rooms",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "room_ids" => room_ids
    }
    |> maybe_put("refund_method", Keyword.get(opts, :refund_method))
    |> maybe_put("expected_revision", Keyword.get(opts, :expected_revision))
  end

  defp reduce_operation(payment_operation_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-reduce-#{payment_operation_id}"),
      "type" => "reduce_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put("expected_revision", Keyword.get(opts, :expected_revision))
  end

  defp charge_back_operation(payment_operation_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-charge-#{payment_operation_id}"),
      "type" => "charge_back_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "payment_operation_id" => payment_operation_id
    }
    |> maybe_put("expected_revision", Keyword.get(opts, :expected_revision))
  end

  defp credit_operation(group_id, amount_cents, opts) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-credit-#{group_id}-#{amount_cents}"),
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, @booked_on),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp submit!(conn, operations) do
    conn = post(conn, "/api/v1/partner-batches", %{"operations" => operations})
    assert conn.status == 200
    json_response(conn, 200)["results"]
  end

  defp apply_op!(conn, operation) do
    [result] = submit!(conn, [operation])
    assert result["status"] == "applied", inspect(result)
    result
  end

  defp open_group!(conn, group_id, opts \\ []) do
    apply_op!(conn, open_operation(group_id, opts))
  end

  defp group_data(group_id) do
    conn = get(build_conn(), "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp room_data(group_id, room_id) do
    Enum.find(group_data(group_id)["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(on \\ nil) do
    conn = get(build_conn(), "/api/v1/ledger" <> on_query(on))
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp guest_credit(guest_id, on) do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> on_query(on))
    assert conn.status == 200
    json_response(conn, 200)["data"]
  end

  defp payment_statement(payment_operation_id) do
    conn = get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
    {conn.status, conn.status == 200 && json_response(conn, 200)["data"]}
  end

  defp on_query(nil), do: ""
  defp on_query(on), do: "?on=#{on}"

  # Funds the guest with a credit lot by cancelling a paid group in credit.
  defp issue_lot!(conn, group_id, cash_cents, cancelled_on) do
    open_group!(conn, group_id)
    apply_op!(conn, payment_operation(group_id, cash_cents, occurred_on: "2026-10-05"))

    apply_op!(
      conn,
      cancel_operation(group_id, occurred_on: cancelled_on, refund_method: "hotel_credit")
    )
  end

  describe "room-level accounting" do
    test "rooms expose their status, deposit, and funding; totals sum the active rooms" do
      conn = build_conn()
      open_group!(conn, "g-rooms")
      apply_op!(conn, payment_operation("g-rooms", 8000))

      data = group_data("g-rooms")

      assert data["rooms"] == [
               %{
                 "room_id" => "room-a",
                 "nightly_rate_cents" => 10000,
                 "status" => "active",
                 "deposit_due_cents" => 6000,
                 "cash_paid_cents" => 6000,
                 "credit_paid_cents" => 0
               },
               %{
                 "room_id" => "room-b",
                 "nightly_rate_cents" => 10000,
                 "status" => "active",
                 "deposit_due_cents" => 6000,
                 "cash_paid_cents" => 2000,
                 "credit_paid_cents" => 0
               }
             ]

      assert data["lodging_total_cents"] == 60_000
      assert data["deposit_due_cents"] == 12_000
      assert data["deposit_paid_cents"] == 8000
      assert data["cash_paid_cents"] == 8000
      assert data["credit_paid_cents"] == 0
      assert data["outstanding_deposit_cents"] == 4000
    end

    test "funding fills one room's deposit before moving to the next" do
      conn = build_conn()
      open_group!(conn, "g-fill")

      # The first payment fills room-a completely and spills into room-b.
      apply_op!(conn, payment_operation("g-fill", 7000, operation_id: "op-fill-1"))
      # The second continues where the first stopped.
      apply_op!(conn, payment_operation("g-fill", 3000, operation_id: "op-fill-2"))

      assert room_data("g-fill", "room-a")["cash_paid_cents"] == 6000
      assert room_data("g-fill", "room-b")["cash_paid_cents"] == 4000
      assert group_data("g-fill")["outstanding_deposit_cents"] == 2000
    end

    test "each room's flexible deposit rounds independently, half upward" do
      conn = build_conn()

      open_group!(conn, "g-round-rooms",
        arrival_on: @arrival_on,
        departure_on: "2027-03-11",
        rooms: [
          # 3333 * 20% = 666.6 -> 667
          %{"room_id" => "room-a", "nightly_rate_cents" => 3333},
          # 25001 * 20% = 5000.2 -> 5000
          %{"room_id" => "room-b", "nightly_rate_cents" => 25_001}
        ]
      )

      assert room_data("g-round-rooms", "room-a")["deposit_due_cents"] == 667
      assert room_data("g-round-rooms", "room-b")["deposit_due_cents"] == 5000
      assert group_data("g-round-rooms")["deposit_due_cents"] == 5667
    end

    test "advance purchase rooms deposit their full lodging" do
      conn = build_conn()

      open_group!(conn, "g-ap-rooms",
        rate_plan: "advance_purchase",
        rooms: [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      )

      assert room_data("g-ap-rooms", "room-a")["deposit_due_cents"] == 30_000
      assert group_data("g-ap-rooms")["lodging_total_cents"] == 30_000
    end

    test "credit funds rooms in the rooms' original order" do
      conn = build_conn()
      issue_lot!(conn, "g-src", 6000, "2027-01-05")

      open_group!(conn, "g-credit-fill",
        occurred_on: "2027-01-10",
        rooms: [
          %{"room_id" => "room-x", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-y", "nightly_rate_cents" => 10000}
        ]
      )

      apply_op!(conn, credit_operation("g-credit-fill", 6600, occurred_on: "2027-01-15"))

      assert room_data("g-credit-fill", "room-x")["credit_paid_cents"] == 6000
      assert room_data("g-credit-fill", "room-y")["credit_paid_cents"] == 600
      assert group_data("g-credit-fill")["deposit_paid_cents"] == 6600
    end

    test "funding from before durable records funds rooms but cannot be targeted" do
      insert_legacy_group("g-legacy-fund", 6000, 6000, 4000)

      data = group_data("g-legacy-fund")
      assert room_data("g-legacy-fund", "room-a")["cash_paid_cents"] == 4000
      assert data["cash_paid_cents"] == 4000
      assert data["outstanding_deposit_cents"] == 8000

      # Legacy funding has no payment identifier: nothing to target.
      assert [reduced] =
               submit!(build_conn(), [reduce_operation("op-legacy-none", 100)])

      assert reduced["code"] == "operation_not_found"

      assert [charged] =
               submit!(build_conn(), [charge_back_operation("op-legacy-none")])

      assert charged["code"] == "operation_not_found"

      assert {404, _} = payment_statement("op-legacy-none")
      assert ledger()["cash_held_cents"] == 4000
    end

    test "a reduction and later funding compose across rooms in fill order" do
      conn = build_conn()
      open_group!(conn, "g-refill")
      apply_op!(conn, payment_operation("g-refill", 8000, operation_id: "op-refill-pay"))

      apply_op!(conn, reduce_operation("op-refill-pay", 3000))
      assert room_data("g-refill", "room-a")["cash_paid_cents"] == 5000
      assert room_data("g-refill", "room-b")["cash_paid_cents"] == 0
      assert group_data("g-refill")["outstanding_deposit_cents"] == 7000

      # New funding allocates after the remaining held cash, topping room-a
      # up before moving to room-b.
      apply_op!(conn, payment_operation("g-refill", 5000, operation_id: "op-refill-pay-2"))
      assert room_data("g-refill", "room-a")["cash_paid_cents"] == 6000
      assert room_data("g-refill", "room-b")["cash_paid_cents"] == 4000
      assert group_data("g-refill")["outstanding_deposit_cents"] == 2000
    end
  end

  describe "cancel_rooms" do
    test "settles the selected rooms and reports them in original order" do
      conn = build_conn()
      open_group!(conn, "g-cr")
      apply_op!(conn, payment_operation("g-cr", 8000, operation_id: "op-cr-pay"))

      # Supplied in reverse: the result uses the group's original order.
      result =
        apply_op!(
          conn,
          cancel_rooms_operation("g-cr", ["room-b", "room-a"], occurred_on: "2027-01-05")
        )

      assert result == %{
               "operation_id" => "op-cancel-rooms-g-cr",
               "status" => "applied",
               "group_id" => "g-cr",
               "cancelled_room_ids" => ["room-a", "room-b"],
               "refunded_cents" => 8000,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      data = group_data("g-cr")
      assert data["status"] == "cancelled"
      assert Enum.all?(data["rooms"], &(&1["status"] == "cancelled"))
      assert data["deposit_due_cents"] == 0
      assert data["outstanding_deposit_cents"] == 0

      assert ledger("2027-01-05") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 8000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "other rooms and their allocations are unchanged" do
      conn = build_conn()
      open_group!(conn, "g-cr-partial")
      apply_op!(conn, payment_operation("g-cr-partial", 8000, operation_id: "op-crp-pay"))

      result =
        apply_op!(
          conn,
          cancel_rooms_operation("g-cr-partial", ["room-a"], occurred_on: "2027-01-05")
        )

      assert result["cancelled_room_ids"] == ["room-a"]
      assert result["refunded_cents"] == 6000

      data = group_data("g-cr-partial")
      assert data["status"] == "active"
      assert data["revision"] == 3
      assert data["deposit_due_cents"] == 6000
      assert data["cash_paid_cents"] == 2000
      assert data["outstanding_deposit_cents"] == 4000

      assert room_data("g-cr-partial", "room-a")["status"] == "cancelled"
      assert room_data("g-cr-partial", "room-a")["cash_paid_cents"] == 0
      assert room_data("g-cr-partial", "room-b")["status"] == "active"
      assert room_data("g-cr-partial", "room-b")["cash_paid_cents"] == 2000

      # The unpaid deposit of the cancelled room is no longer due, so a
      # payment covering the rest of room-b is accepted.
      result =
        apply_op!(conn, payment_operation("g-cr-partial", 4000, operation_id: "op-crp-pay-2"))

      assert result["outstanding_deposit_cents"] == 0
    end

    test "non-refundable settlement retains the selected rooms' cash" do
      conn = build_conn()
      open_group!(conn, "g-cr-late")
      apply_op!(conn, payment_operation("g-cr-late", 8000, operation_id: "op-crl-pay"))

      # 2027-03-01 is nine days before arrival: non-refundable.
      result =
        apply_op!(
          conn,
          cancel_rooms_operation("g-cr-late", ["room-a"], occurred_on: "2027-03-01")
        )

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 6000
      assert group_data("g-cr-late")["status"] == "active"

      assert ledger("2027-03-01")["cash_retained_cents"] == 6000
      assert ledger("2027-03-01")["cash_held_cents"] == 2000
    end

    test "hotel credit computes the bonus once on the combined cash" do
      conn = build_conn()
      open_group!(conn, "g-cr-credit")
      apply_op!(conn, payment_operation("g-cr-credit", 9000, operation_id: "op-crc-pay"))

      result =
        apply_op!(
          conn,
          cancel_rooms_operation("g-cr-credit", ["room-a", "room-b"],
            occurred_on: "2027-01-05",
            refund_method: "hotel_credit"
          )
        )

      # One lot of 9900 for combined cash of 9000, not two lots of 6600 and
      # 3300.
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 9900

      assert guest_credit(@guest, "2027-01-05") == %{
               "guest_id" => @guest,
               "available_cents" => 9900,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-rooms-g-cr-credit",
                   "remaining_cents" => 9900,
                   "expires_on" => "2028-01-06"
                 }
               ]
             }

      assert ledger("2027-01-05")["cash_converted_to_credit_cents"] == 9000
    end

    test "hotel credit is unavailable for a non-refundable settlement" do
      conn = build_conn()
      open_group!(conn, "g-cr-no-credit")
      apply_op!(conn, payment_operation("g-cr-no-credit", 5000, operation_id: "op-crnc-pay"))

      [result] =
        submit!(conn, [
          cancel_rooms_operation("g-cr-no-credit", ["room-a"],
            occurred_on: "2027-03-01",
            refund_method: "hotel_credit"
          )
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"

      data = group_data("g-cr-no-credit")
      assert data["status"] == "active"
      assert Enum.all?(data["rooms"], &(&1["status"] == "active"))
      assert data["revision"] == 2
    end

    test "credit funding the selected rooms is restored or consumed" do
      conn = build_conn()
      issue_lot!(conn, "g-src-restore", 6000, "2027-01-05")

      open_group!(conn, "g-cr-restore", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cr-restore", 6600, occurred_on: "2027-01-15"))

      # Refundable: room-a's credit returns to its lot, whole.
      apply_op!(
        conn,
        cancel_rooms_operation("g-cr-restore", ["room-a"], occurred_on: "2027-02-01")
      )

      assert room_data("g-cr-restore", "room-a")["credit_paid_cents"] == 0
      assert room_data("g-cr-restore", "room-b")["credit_paid_cents"] == 600
      assert guest_credit(@guest, "2027-02-01")["available_cents"] == 6000

      # Non-refundable: the remaining credit is consumed, not restored.
      apply_op!(
        conn,
        cancel_rooms_operation("g-cr-restore", ["room-b"],
          occurred_on: "2027-03-01",
          operation_id: "op-cancel-rooms-g-cr-restore-2"
        )
      )

      assert guest_credit(@guest, "2027-03-01")["available_cents"] == 6000
      assert ledger("2027-03-01")["credit_liability_cents"] == 6000
    end

    test "rejects room identifiers that are not distinct active rooms" do
      conn = build_conn()
      open_group!(conn, "g-cr-invalid")
      apply_op!(conn, payment_operation("g-cr-invalid", 1000, operation_id: "op-cri-pay"))

      apply_op!(
        conn,
        cancel_rooms_operation("g-cr-invalid", ["room-a"], occurred_on: "2027-01-05")
      )

      invalid = [
        # Unknown room.
        ["room-z"],
        # Not distinct.
        ["room-b", "room-b"],
        # Already cancelled.
        ["room-a"],
        # Empty.
        [],
        # Not room identifiers at all.
        [17],
        # Mix of valid and invalid.
        ["room-b", "room-z"]
      ]

      for {room_ids, index} <- Enum.with_index(invalid) do
        [result] =
          submit!(conn, [
            cancel_rooms_operation("g-cr-invalid", room_ids,
              occurred_on: "2027-01-05",
              operation_id: "op-cri-#{index}"
            )
          ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_rooms", inspect(room_ids)
      end

      # A missing room_ids list cannot identify the operation's target.
      [result] =
        submit!(conn, [
          %{
            "operation_id" => "op-cri-missing",
            "type" => "cancel_rooms",
            "occurred_on" => @booked_on,
            "group_id" => "g-cr-invalid"
          }
        ])

      assert result["code"] == "invalid_operation"

      data = group_data("g-cr-invalid")
      assert data["status"] == "active"
      assert data["revision"] == 3
      assert room_data("g-cr-invalid", "room-a")["status"] == "cancelled"
      assert room_data("g-cr-invalid", "room-b")["status"] == "active"
    end

    test "uses the group errors and revision contract" do
      conn = build_conn()
      open_group!(conn, "g-cr-rev")

      [missing] = submit!(conn, [cancel_rooms_operation("g-cr-none", ["room-a"])])
      assert missing["code"] == "group_not_found"

      [stale] =
        submit!(conn, [
          cancel_rooms_operation("g-cr-rev", ["room-a"],
            occurred_on: "2027-01-05",
            expected_revision: 7
          )
        ])

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 1

      # A fresh identifier: retrying the stale one under its own identifier
      # with a corrected revision is a different payload and conflicts.
      result =
        apply_op!(
          conn,
          cancel_rooms_operation("g-cr-rev", ["room-a"],
            occurred_on: "2027-01-05",
            expected_revision: 1,
            operation_id: "op-cancel-rooms-g-cr-rev-apply"
          )
        )

      assert result["revision"] == 2

      # Cancelling the last active room cancels the group.
      result =
        apply_op!(
          conn,
          cancel_rooms_operation("g-cr-rev", ["room-b"],
            occurred_on: "2027-01-06",
            operation_id: "op-cancel-rooms-g-cr-rev-2"
          )
        )

      assert result["revision"] == 3
      assert group_data("g-cr-rev")["status"] == "cancelled"

      [done] =
        submit!(conn, [
          cancel_rooms_operation("g-cr-rev", [],
            occurred_on: "2027-01-07",
            operation_id: "op-cancel-rooms-g-cr-rev-3"
          )
        ])

      assert done["code"] == "group_not_active"
    end

    test "cancel_group settles only the remaining active rooms" do
      conn = build_conn()
      open_group!(conn, "g-cr-then-group")
      apply_op!(conn, payment_operation("g-cr-then-group", 8000, operation_id: "op-crtg-pay"))

      apply_op!(
        conn,
        cancel_rooms_operation("g-cr-then-group", ["room-a"], occurred_on: "2027-01-05")
      )

      # Only room-b's held cash is left to settle.
      result =
        apply_op!(
          conn,
          cancel_operation("g-cr-then-group", occurred_on: "2027-02-01")
        )

      assert result["refunded_cents"] == 2000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0
      assert result["revision"] == 4

      data = group_data("g-cr-then-group")
      assert data["status"] == "cancelled"
      assert Enum.all?(data["rooms"], &(&1["status"] == "cancelled"))

      assert ledger("2027-02-01")["cash_refunded_cents"] == 8000
    end
  end

  describe "reduce_cash_payment" do
    test "removes held cash of the target payment in reverse fill order" do
      conn = build_conn()
      open_group!(conn, "g-reduce")
      apply_op!(conn, payment_operation("g-reduce", 8000, operation_id: "op-reduce-pay"))

      result = apply_op!(conn, reduce_operation("op-reduce-pay", 3000))

      assert result == %{
               "operation_id" => "op-reduce-op-reduce-pay",
               "status" => "applied",
               "payment_operation_id" => "op-reduce-pay",
               "group_id" => "g-reduce",
               "amount_cents" => 3000,
               "outstanding_deposit_cents" => 7000,
               "revision" => 3
             }

      # Reverse fill order: the reduction comes out of room-b's 2000 and
      # the last 1000 of room-a, not out of room-a's first-filled cash.
      assert room_data("g-reduce", "room-a")["cash_paid_cents"] == 5000
      assert room_data("g-reduce", "room-b")["cash_paid_cents"] == 0
      assert group_data("g-reduce")["outstanding_deposit_cents"] == 7000

      assert ledger()["cash_held_cents"] == 5000
      assert ledger()["cash_reduced_cents"] == 3000
    end

    test "successive reductions compose against the remaining held cash" do
      conn = build_conn()
      open_group!(conn, "g-reduce-twice")
      apply_op!(conn, payment_operation("g-reduce-twice", 5000, operation_id: "op-rt-pay"))

      first = apply_op!(conn, reduce_operation("op-rt-pay", 2000))
      assert first["outstanding_deposit_cents"] == 9000

      # A reduction equal to the complete remaining held portion is valid.
      second =
        apply_op!(
          conn,
          reduce_operation("op-rt-pay", 3000,
            operation_id: "op-reduce-op-rt-pay-2",
            expected_revision: 3
          )
        )

      assert second["amount_cents"] == 3000
      assert second["outstanding_deposit_cents"] == 12_000
      assert second["revision"] == 4

      assert group_data("g-reduce-twice")["cash_paid_cents"] == 0
      assert ledger()["cash_reduced_cents"] == 5000
      assert ledger()["cash_held_cents"] == 0
    end

    test "reduces only the target payment's cash" do
      conn = build_conn()
      open_group!(conn, "g-reduce-target")
      apply_op!(conn, payment_operation("g-reduce-target", 4000, operation_id: "op-rt-pay-a"))
      apply_op!(conn, payment_operation("g-reduce-target", 4000, operation_id: "op-rt-pay-b"))

      apply_op!(conn, reduce_operation("op-rt-pay-b", 2000))

      # room-a was filled by pay-a (4000) and 2000 of pay-b; the reduction
      # removes pay-b's cash from reverse fill order.
      assert room_data("g-reduce-target", "room-a")["cash_paid_cents"] == 6000
      assert room_data("g-reduce-target", "room-b")["cash_paid_cents"] == 0

      # pay-a is untouched.
      {200, statement} = payment_statement("op-rt-pay-a")
      assert statement["held_cents"] == 4000
      assert statement["reduced_cents"] == 0
    end

    test "rejects unusable targets and amounts with the documented codes" do
      conn = build_conn()
      open_group!(conn, "g-reduce-codes")
      apply_op!(conn, payment_operation("g-reduce-codes", 5000, operation_id: "op-rc-pay"))

      # No durable record at all.
      [result] = submit!(conn, [reduce_operation("op-never", 100)])
      assert result["code"] == "operation_not_found"

      # A durable record that is not a payment.
      [result] =
        submit!(conn, [reduce_operation("op-open-g-reduce-codes", 100, operation_id: "op-rc-1")])

      assert result["code"] == "payment_not_reducible"

      # A rejected payment.
      [rejected] =
        submit!(conn, [
          payment_operation("g-reduce-codes", 25_000, operation_id: "op-rc-reject-me")
        ])

      assert rejected["code"] == "payment_exceeds_outstanding"

      [result] =
        submit!(conn, [reduce_operation("op-rc-reject-me", 100, operation_id: "op-rc-2")])

      assert result["code"] == "payment_not_reducible"

      # Non-positive amounts.
      for {amount, index} <- Enum.with_index([0, -100]) do
        [result] =
          submit!(conn, [
            reduce_operation("op-rc-pay", amount, operation_id: "op-rc-amount-#{index}")
          ])

        assert result["code"] == "invalid_amount"
      end

      # More than the payment's held cash, though less would succeed.
      [result] = submit!(conn, [reduce_operation("op-rc-pay", 5001, operation_id: "op-rc-3")])
      assert result["code"] == "reduction_exceeds_held_cash"

      # Once no held cash remains, the payment can never be reduced again.
      apply_op!(conn, reduce_operation("op-rc-pay", 5000, operation_id: "op-rc-4"))

      [result] = submit!(conn, [reduce_operation("op-rc-pay", 1, operation_id: "op-rc-5")])
      assert result["code"] == "payment_not_reducible"

      # Settled history never moves through a reduction either.
      open_group!(conn, "g-reduce-settled")
      apply_op!(conn, payment_operation("g-reduce-settled", 5000, operation_id: "op-rs-pay"))
      apply_op!(conn, cancel_operation("g-reduce-settled", occurred_on: "2027-01-05"))

      [result] = submit!(conn, [reduce_operation("op-rs-pay", 100, operation_id: "op-rc-6")])
      assert result["code"] == "payment_not_reducible"

      # Only the applied payment and the applied reduction moved it.
      assert group_data("g-reduce-codes")["revision"] == 3
    end

    test "retrying the original payment replays its result without reapplying" do
      conn = build_conn()
      open_group!(conn, "g-reduce-retry")

      [original] =
        submit!(conn, [payment_operation("g-reduce-retry", 5000, operation_id: "op-rr-pay")])

      apply_op!(conn, reduce_operation("op-rr-pay", 2000))

      [retry] =
        submit!(conn, [payment_operation("g-reduce-retry", 5000, operation_id: "op-rr-pay")])

      assert retry == original
      assert retry["outstanding_deposit_cents"] == 7000

      # No cash was reapplied: 3000 held, 2000 reduced.
      assert ledger()["cash_held_cents"] == 3000
      assert ledger()["cash_reduced_cents"] == 2000
      assert group_data("g-reduce-retry")["cash_paid_cents"] == 3000
    end

    test "follows the revision contract against the payment's group" do
      conn = build_conn()
      open_group!(conn, "g-reduce-rev")
      apply_op!(conn, payment_operation("g-reduce-rev", 5000, operation_id: "op-rrv-pay"))

      [stale] =
        submit!(conn, [
          reduce_operation("op-rrv-pay", 100,
            operation_id: "op-rrv-1",
            expected_revision: 9
          )
        ])

      assert stale["code"] == "stale_revision"
      assert stale["group_id"] == "g-reduce-rev"
      assert stale["actual_revision"] == 2

      result =
        apply_op!(
          conn,
          reduce_operation("op-rrv-pay", 100,
            operation_id: "op-rrv-2",
            expected_revision: 2
          )
        )

      assert result["revision"] == 3
    end
  end

  describe "charge_back_payment" do
    test "reverses held cash of an active group and reopens the deposit" do
      conn = build_conn()
      open_group!(conn, "g-cb")
      apply_op!(conn, payment_operation("g-cb", 8000, operation_id: "op-cb-pay"))

      result = apply_op!(conn, charge_back_operation("op-cb-pay"))

      assert result == %{
               "operation_id" => "op-charge-op-cb-pay",
               "status" => "applied",
               "payment_operation_id" => "op-cb-pay",
               "group_id" => "g-cb",
               "charged_back_cents" => 8000,
               "outstanding_deposit_cents" => 12_000,
               "revision" => 3
             }

      assert group_data("g-cb")["cash_paid_cents"] == 0
      assert group_data("g-cb")["status"] == "active"

      assert ledger() == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 8000,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }

      # The reopened deposit accepts fresh funding.
      apply_op!(conn, payment_operation("g-cb", 1000, operation_id: "op-cb-pay-2"))
      assert room_data("g-cb", "room-a")["cash_paid_cents"] == 1000
    end

    test "reclassifies refunded and retained history without reissuing it" do
      conn = build_conn()

      open_group!(conn, "g-cb-refunded")
      apply_op!(conn, payment_operation("g-cb-refunded", 5000, operation_id: "op-cbr-pay"))
      apply_op!(conn, cancel_operation("g-cb-refunded", occurred_on: "2027-01-05"))

      open_group!(conn, "g-cb-retained")
      apply_op!(conn, payment_operation("g-cb-retained", 5000, operation_id: "op-cbt-pay"))
      apply_op!(conn, cancel_operation("g-cb-retained", occurred_on: "2027-03-01"))

      assert ledger("2027-03-02")["cash_refunded_cents"] == 5000
      assert ledger("2027-03-02")["cash_retained_cents"] == 5000

      apply_op!(conn, charge_back_operation("op-cbr-pay"))
      apply_op!(conn, charge_back_operation("op-cbt-pay"))

      assert ledger("2027-03-02")["cash_refunded_cents"] == 0
      assert ledger("2027-03-02")["cash_retained_cents"] == 0
      assert ledger("2027-03-02")["cash_charged_back_cents"] == 10_000

      # A chargeback works on a cancelled group and bumps its revision once.
      assert group_data("g-cb-refunded")["revision"] == 4
      assert group_data("g-cb-refunded")["status"] == "cancelled"
    end

    test "keeps an already reduced portion reduced" do
      conn = build_conn()
      open_group!(conn, "g-cb-reduced")
      apply_op!(conn, payment_operation("g-cb-reduced", 5000, operation_id: "op-cbrd-pay"))
      apply_op!(conn, reduce_operation("op-cbrd-pay", 2000))

      result = apply_op!(conn, charge_back_operation("op-cbrd-pay"))

      assert result["charged_back_cents"] == 3000

      {200, statement} = payment_statement("op-cbrd-pay")
      assert statement["reduced_cents"] == 2000
      assert statement["charged_back_cents"] == 3000
      assert statement["recorded_cents"] == 5000
    end

    test "revokes the credit entitlement a converted payment created" do
      conn = build_conn()
      open_group!(conn, "g-cb-credit")
      apply_op!(conn, payment_operation("g-cb-credit", 3000, operation_id: "op-cbc-pay-1"))
      apply_op!(conn, payment_operation("g-cb-credit", 2000, operation_id: "op-cbc-pay-2"))

      apply_op!(
        conn,
        cancel_operation("g-cb-credit", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      # One lot of 5500 from combined cash of 5000: pay-1's entitlement is
      # 3300 (bonus value through it) and pay-2's is 2200.
      assert guest_credit(@guest, "2027-01-06")["available_cents"] == 5500

      result = apply_op!(conn, charge_back_operation("op-cbc-pay-1"))

      assert result["charged_back_cents"] == 3000

      assert guest_credit(@guest, "2027-01-06") == %{
               "guest_id" => @guest,
               "available_cents" => 2200,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-g-cb-credit",
                   "remaining_cents" => 2200,
                   "expires_on" => "2028-01-06"
                 }
               ]
             }

      assert ledger("2027-01-06")["cash_converted_to_credit_cents"] == 2000
      assert ledger("2027-01-06")["cash_charged_back_cents"] == 3000
      assert ledger("2027-01-06")["credit_liability_cents"] == 2200
      assert ledger("2027-01-06")["credit_shortfall_cents"] == 0

      # The other payment's entitlement is untouched: it can still be
      # charged back for 2200 of lot credit.
      result = apply_op!(conn, charge_back_operation("op-cbc-pay-2"))
      assert result["charged_back_cents"] == 2000
      assert guest_credit(@guest, "2027-01-06")["available_cents"] == 0
    end

    test "a spent entitlement becomes unrecovered clawback and shortfall" do
      conn = build_conn()
      open_group!(conn, "g-cb-src")
      apply_op!(conn, payment_operation("g-cb-src", 3000, operation_id: "op-cbs-pay"))

      apply_op!(
        conn,
        cancel_operation("g-cb-src", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      # The lot (3300) is applied to another active group in full.
      open_group!(conn, "g-cb-use", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cb-use", 3300, occurred_on: "2027-01-15"))

      assert ledger("2027-01-16")["credit_liability_cents"] == 3300

      # The payment's full entitlement is now funding the other group, so
      # none of it can be removed from the lot's remaining balance.
      apply_op!(conn, charge_back_operation("op-cbs-pay"))

      assert ledger("2027-01-16")["credit_liability_cents"] == 3300
      assert ledger("2027-01-16")["credit_shortfall_cents"] == 3300

      # Credit still funding an active group keeps the lot's shortfall
      # current even though the entitlement was revoked.
      assert guest_credit(@guest, "2027-01-16")["available_cents"] == 0

      # Non-refundable settlement consumes the credit: no group holds the
      # lot's credit anymore, so the current shortfall drops to zero.
      apply_op!(conn, cancel_operation("g-cb-use", occurred_on: "2027-03-01"))
      assert ledger("2027-03-02")["credit_shortfall_cents"] == 0
      assert ledger("2027-03-02")["credit_liability_cents"] == 0
      assert guest_credit(@guest, "2027-03-02")["available_cents"] == 0
    end

    test "credit returning to a shortfalled lot is absorbed by the clawback" do
      conn = build_conn()
      open_group!(conn, "g-cb-abs-src")
      apply_op!(conn, payment_operation("g-cb-abs-src", 3000, operation_id: "op-cba-pay"))

      apply_op!(
        conn,
        cancel_operation("g-cb-abs-src", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      open_group!(conn, "g-cb-abs-use", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cb-abs-use", 3300, occurred_on: "2027-01-15"))

      apply_op!(conn, charge_back_operation("op-cba-pay"))
      assert ledger("2027-01-16")["credit_shortfall_cents"] == 3300

      # A refundable cancellation returns the credit to its lot: the
      # clawback absorbs all of it before any amount becomes available.
      apply_op!(conn, cancel_operation("g-cb-abs-use", occurred_on: "2027-02-01"))

      assert guest_credit(@guest, "2027-02-02")["available_cents"] == 0
      assert ledger("2027-02-02")["credit_shortfall_cents"] == 0
      assert ledger("2027-02-02")["credit_liability_cents"] == 0

      # Only an excess over the clawback would become available again.
    end

    test "an excess over the clawback becomes available again" do
      conn = build_conn()
      # Two payments convert into one lot worth 5500.
      open_group!(conn, "g-cb-exc-src")
      apply_op!(conn, payment_operation("g-cb-exc-src", 3000, operation_id: "op-cbe-pay-1"))
      apply_op!(conn, payment_operation("g-cb-exc-src", 2000, operation_id: "op-cbe-pay-2"))

      apply_op!(
        conn,
        cancel_operation("g-cb-exc-src", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      # Spend 2200 of the lot, leaving 3300 available.
      open_group!(conn, "g-cb-exc-use", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cb-exc-use", 2200, occurred_on: "2027-01-15"))

      # Charge back pay-2 (entitlement 2200): all of it is removed from the
      # lot's remaining balance, so no clawback arises.
      apply_op!(conn, charge_back_operation("op-cbe-pay-2"))
      assert guest_credit(@guest, "2027-01-16")["available_cents"] == 1100
      assert ledger("2027-01-16")["credit_shortfall_cents"] == 0

      # Charge back pay-1 (entitlement 3300): only 1100 can be removed; the
      # remaining 2200 become unrecovered clawback.
      apply_op!(conn, charge_back_operation("op-cbe-pay-1"))
      assert guest_credit(@guest, "2027-01-16")["available_cents"] == 0

      # The 2200 still funding g-cb-exc-use returns to the lot on a
      # refundable cancellation: the clawback absorbs 2200 and nothing is
      # left available.
      apply_op!(conn, cancel_operation("g-cb-exc-use", occurred_on: "2027-02-01"))
      assert guest_credit(@guest, "2027-02-02")["available_cents"] == 0
      assert ledger("2027-02-02")["credit_liability_cents"] == 0
    end

    test "rejects unusable targets with the documented codes" do
      conn = build_conn()
      open_group!(conn, "g-cb-codes")
      apply_op!(conn, payment_operation("g-cb-codes", 5000, operation_id: "op-cbcodes-pay"))

      [result] = submit!(conn, [charge_back_operation("op-never")])
      assert result["code"] == "operation_not_found"

      [result] =
        submit!(conn, [charge_back_operation("op-open-g-cb-codes", operation_id: "op-cb-1")])

      assert result["code"] == "payment_not_chargeable"

      apply_op!(conn, charge_back_operation("op-cbcodes-pay"))

      [again] =
        submit!(conn, [charge_back_operation("op-cbcodes-pay", operation_id: "op-cb-2")])

      assert again["code"] == "payment_not_chargeable"

      # A fully reduced payment has nothing left to charge back.
      open_group!(conn, "g-cb-full-reduced")
      apply_op!(conn, payment_operation("g-cb-full-reduced", 3000, operation_id: "op-cbfr-pay"))
      apply_op!(conn, reduce_operation("op-cbfr-pay", 3000))

      [result] =
        submit!(conn, [charge_back_operation("op-cbfr-pay", operation_id: "op-cb-3")])

      assert result["code"] == "payment_not_chargeable"

      assert group_data("g-cb-codes")["revision"] == 3
    end

    test "increments only the original payment group's revision, once" do
      conn = build_conn()
      open_group!(conn, "g-cb-rev-src")
      apply_op!(conn, payment_operation("g-cb-rev-src", 3000, operation_id: "op-cbrev-pay"))

      apply_op!(
        conn,
        cancel_operation("g-cb-rev-src", occurred_on: "2027-01-05", refund_method: "hotel_credit")
      )

      open_group!(conn, "g-cb-rev-use", occurred_on: "2027-01-10")
      apply_op!(conn, credit_operation("g-cb-rev-use", 2200, occurred_on: "2027-01-15"))

      revision_before = group_data("g-cb-rev-use")["revision"]

      result = apply_op!(conn, charge_back_operation("op-cbrev-pay"))

      assert result["revision"] == 4
      assert group_data("g-cb-rev-src")["revision"] == 4
      assert group_data("g-cb-rev-use")["revision"] == revision_before
      assert group_data("g-cb-rev-use")["status"] == "active"

      # A mismatched revision is rejected before the domain rules.
      [stale] =
        submit!(conn, [
          charge_back_operation("op-cbrev-pay",
            operation_id: "op-cbrev-stale",
            expected_revision: 1
          )
        ])

      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 4
    end
  end

  describe "payment reconciliation" do
    test "reports every disposition of a payment, agreeing with the other views" do
      conn = build_conn()
      open_group!(conn, "g-rec")
      apply_op!(conn, payment_operation("g-rec", 8000, operation_id: "op-rec-pay"))
      apply_op!(conn, reduce_operation("op-rec-pay", 3000))

      {200, statement} = payment_statement("op-rec-pay")

      assert statement == %{
               "payment_operation_id" => "op-rec-pay",
               "original_group_id" => "g-rec",
               "recorded_cents" => 8000,
               "held_cents" => 5000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3000,
               "charged_back_cents" => 0
             }

      # The six dispositions sum to the recorded cash.
      assert statement["held_cents"] + statement["refunded_cents"] + statement["retained_cents"] +
               statement["converted_to_credit_cents"] + statement["reduced_cents"] +
               statement["charged_back_cents"] == statement["recorded_cents"]

      # And agree with the group, room, and ledger views.
      assert group_data("g-rec")["cash_paid_cents"] == statement["held_cents"]
      assert ledger()["cash_held_cents"] == statement["held_cents"]
      assert ledger()["cash_reduced_cents"] == statement["reduced_cents"]

      # Reading a statement never changes state.
      assert payment_statement("op-rec-pay") == {200, statement}
      assert group_data("g-rec")["cash_paid_cents"] == 5000
    end

    test "reports every disposition of a settled payment" do
      conn = build_conn()
      issue_lot!(conn, "g-rec-credit-src", 2000, "2027-01-05")

      open_group!(conn, "g-rec-credit", occurred_on: "2027-01-10")

      apply_op!(
        conn,
        payment_operation("g-rec-credit", 3000,
          occurred_on: "2027-01-11",
          operation_id: "op-rec-c-pay"
        )
      )

      apply_op!(conn, credit_operation("g-rec-credit", 2200, occurred_on: "2027-01-12"))

      # Non-refundable: cash retained, credit consumed.
      apply_op!(conn, cancel_operation("g-rec-credit", occurred_on: "2027-03-01"))

      {200, statement} = payment_statement("op-rec-c-pay")
      assert statement["held_cents"] == 0
      assert statement["retained_cents"] == 3000
      assert statement["reduced_cents"] == 0

      # Charged back afterwards: retained history is reclassified.
      apply_op!(conn, charge_back_operation("op-rec-c-pay"))
      {200, statement} = payment_statement("op-rec-c-pay")
      assert statement["charged_back_cents"] == 3000
      assert statement["retained_cents"] == 0
    end

    test "returns 404 for unknown operations and 422 for non-payments" do
      conn = build_conn()
      open_group!(conn, "g-rec-errors")

      assert {404, _} = payment_statement("op-unknown-payment")
      conn404 = get(build_conn(), "/api/v1/payments/op-unknown-payment")
      assert json_response(conn404, 404) == %{"error" => %{"code" => "operation_not_found"}}

      # An operation that is not a cash payment cannot be reconciled.
      conn422 = get(build_conn(), "/api/v1/payments/op-open-g-rec-errors")
      assert json_response(conn422, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}

      # Neither can a rejected payment.
      [rejected] =
        submit!(conn, [payment_operation("g-rec-errors", 25_000, operation_id: "op-rej-pay")])

      assert rejected["code"] == "payment_exceeds_outstanding"

      conn422 = get(build_conn(), "/api/v1/payments/op-rej-pay")
      assert json_response(conn422, 422) == %{"error" => %{"code" => "payment_not_reconcilable"}}
    end
  end

  describe "durable idempotency of the new operations" do
    test "an identical cancel_rooms retry replays its result without resettling" do
      conn = build_conn()
      open_group!(conn, "g-cr-retry")
      apply_op!(conn, payment_operation("g-cr-retry", 8000, operation_id: "op-crr-pay"))

      operation = cancel_rooms_operation("g-cr-retry", ["room-a"], occurred_on: "2027-01-05")
      [first] = submit!(conn, [operation])
      assert first["status"] == "applied"

      [retry] = submit!(conn, [operation])
      assert retry == first

      # Only one settlement happened.
      assert ledger("2027-01-05")["cash_refunded_cents"] == 6000
      assert group_data("g-cr-retry")["revision"] == 3
    end

    test "an identical reduce retry replays its result without reducing twice" do
      conn = build_conn()
      open_group!(conn, "g-reduce-retry-2")
      apply_op!(conn, payment_operation("g-reduce-retry-2", 5000, operation_id: "op-rr2-pay"))

      operation = reduce_operation("op-rr2-pay", 2000)
      [first] = submit!(conn, [operation])
      assert first["status"] == "applied"

      [retry] = submit!(conn, [operation])
      assert retry == first

      assert ledger()["cash_reduced_cents"] == 2000
      assert group_data("g-reduce-retry-2")["revision"] == 3

      # A different payload under the same identifier conflicts.
      conflicting =
        reduce_operation("op-rr2-pay", 1000)
        |> Map.put("operation_id", "op-reduce-op-rr2-pay")

      [conflict] = submit!(conn, [conflicting])

      assert conflict["code"] == "operation_id_conflict"
      assert ledger()["cash_reduced_cents"] == 2000
    end
  end

  # Inserts the steady state a deployment upgrade produces for a group whose
  # funding predates durable operation records: an unattributed payment and
  # its room allocation, brought forward as the senior block.
  defp insert_legacy_group(group_id, room_a_due, room_b_due, cash_cents) do
    {:ok, group} =
      Repo.insert(%GroupStay.Groups.Group{
        group_id: group_id,
        guest_id: @guest,
        property_id: "ams-canal",
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2027-03-10],
        departure_on: ~D[2027-03-13],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "active",
        revision: 1,
        lodging_total_cents: (room_a_due + room_b_due) * 5,
        deposit_due_cents: room_a_due + room_b_due
      })

    for {room_id, due, position} <- [{"room-a", room_a_due, 0}, {"room-b", room_b_due, 1}] do
      {:ok, _} =
        Repo.insert(%GroupStay.Groups.Room{
          group_id: group.id,
          room_id: room_id,
          nightly_rate_cents: div(due * 5, 1),
          position: position,
          status: "active",
          deposit_due_cents: due
        })
    end

    {:ok, _} =
      Repo.insert(%GroupStay.Groups.Payment{
        group_id: group.id,
        amount_cents: cash_cents,
        recorded_on: ~D[2026-10-04]
      })

    room =
      Repo.get_by(GroupStay.Groups.Room, group_id: group.id, room_id: "room-a")

    {:ok, _} =
      Repo.insert(%GroupStay.Groups.Allocation{
        group_id: group.id,
        room_id: room.id,
        source: "cash",
        amount_cents: cash_cents,
        state: "held"
      })

    :ok
  end
end
