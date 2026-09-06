defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Operations.Record

  # The default group: booked 2026-10-03 (flex-14), arrival 2026-12-10,
  # deposit due 19500.
  @issue_cancel_on "2026-11-20"

  defp results(conn), do: conn |> json_response(200) |> Map.fetch!("results")

  describe "retrying an applied operation replays the exact original result" do
    test "the stored revision and totals are returned without consulting current state", %{
      conn: conn
    } do
      original =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000, %{"operation_id" => "op-pay-one"}),
          payment_operation("group-81", 2000, %{"operation_id" => "op-pay-two"})
        ])
        |> results()
        |> Enum.at(1)

      assert %{"status" => "applied", "outstanding_deposit_cents" => 18_500, "revision" => 2} =
               original

      # The group has moved on since, but an exact retry still sees the first
      # attempt's answer verbatim.
      retry_result =
        post_operations(conn, [
          payment_operation("group-81", 1000, %{"operation_id" => "op-pay-one"})
        ])
        |> results()
        |> hd()

      assert retry_result == original

      # The replay changed nothing: no third payment, no revision bump.
      assert %{"data" => %{"revision" => 3, "deposit_paid_cents" => 3000}} =
               get_group(conn, "group-81") |> json_response(200)

      assert %{"data" => %{"cash_held_cents" => 3000}} = get_ledger(conn) |> json_response(200)
    end

    test "a retry is answered even when current state would reject the operation", %{conn: conn} do
      original =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6000, %{"operation_id" => "op-pay-one"}),
          cancel_operation("group-81")
        ])
        |> results()
        |> Enum.at(1)

      assert %{"status" => "applied", "outstanding_deposit_cents" => 13_500} = original

      # The group is cancelled now; the retry still returns the original
      # result instead of a group_not_active rejection.
      retry_result =
        post_operations(conn, [
          payment_operation("group-81", 6000, %{"operation_id" => "op-pay-one"})
        ])
        |> results()
        |> hd()

      assert retry_result == original
    end
  end

  describe "rejected operations are remembered like applied ones" do
    test "a stale-revision retry repeats the observed revisions verbatim", %{conn: conn} do
      stale_op = fn extra ->
        Map.merge(
          %{
            "operation_id" => "op-stale",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-81",
            "amount_cents" => 1000,
            "expected_revision" => 5
          },
          extra
        )
      end

      original =
        post_operations(conn, [open_operation(), stale_op.(%{})])
        |> results()
        |> Enum.at(1)

      assert %{
               "status" => "rejected",
               "code" => "stale_revision",
               "expected_revision" => 5,
               "actual_revision" => 1
             } = original

      # Advance the group; a fresh attempt with the same payload must still
      # report the originally observed actual_revision of 1.
      conn = post_operations(conn, [payment_operation("group-81", 500)])
      assert [%{"status" => "applied", "revision" => 2}] = results(conn)

      retry_result = post_operations(conn, [stale_op.(%{})]) |> results() |> hd()
      assert retry_result == original

      # Correcting expected_revision under the same identifier is a different
      # payload and conflicts instead of replacing the record.
      corrected =
        post_operations(conn, [stale_op.(%{"expected_revision" => 4})]) |> results() |> hd()

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = corrected

      # And the original record survives the conflicting submission.
      assert post_operations(conn, [stale_op.(%{})]) |> results() |> hd() == original
    end

    test "a rejection is kept even after later operations would make it valid", %{conn: conn} do
      conn =
        issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "new-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          apply_credit_operation("new-group", 6600, %{
            "operation_id" => "op-spend-all",
            "occurred_on" => "2027-02-10"
          }),
          apply_credit_operation("new-group", 700, %{
            "operation_id" => "op-late-spend",
            "occurred_on" => "2027-02-11"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "insufficient_credit"}
             ] = results(conn)

      # A refundable cancellation restores the spent credit, so the retried
      # operation would now succeed — yet its remembered rejection stands.
      conn =
        post_operations(conn, [
          cancel_operation("new-group", %{"occurred_on" => "2027-03-02"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      retry_result =
        post_operations(conn, [
          apply_credit_operation("new-group", 700, %{
            "operation_id" => "op-late-spend",
            "occurred_on" => "2027-02-11"
          })
        ])
        |> results()
        |> hd()

      assert %{"status" => "rejected", "code" => "insufficient_credit"} = retry_result

      assert %{"available_cents" => 6600} = guest_credit(conn, "guest-22", "2027-03-03")
    end

    test "invalid operations are remembered under their identifier too", %{conn: conn} do
      bogus = %{"operation_id" => "op-warp", "type" => "warp_group", "group_id" => "group-81"}

      conn = post_operations(conn, [open_operation()])
      assert [%{"status" => "applied"}] = results(conn)

      first = post_operations(conn, [bogus]) |> results() |> hd()
      assert %{"status" => "rejected", "code" => "invalid_operation"} = first

      exact_retry = post_operations(conn, [bogus]) |> results() |> hd()
      assert exact_retry == first

      variant = post_operations(conn, [Map.merge(bogus, %{"extra" => true})]) |> results() |> hd()

      assert %{"status" => "rejected", "code" => "operation_id_conflict"} = variant

      assert post_operations(conn, [bogus]) |> results() |> hd() == first

      assert %{"data" => %{"revision" => 1}} = get_group(conn, "group-81") |> json_response(200)
    end
  end

  describe "payload equivalence" do
    @base_submission """
    {
      "operation_id": "op-key-order",
      "type": "open_group",
      "occurred_on": "2026-10-03",
      "group_id": "key-group",
      "guest_id": "guest-22",
      "property_id": "ams-canal",
      "arrival_on": "2026-12-10",
      "departure_on": "2026-12-13",
      "rate_plan": "flexible",
      "rooms": [
        {"room_id": "room-a", "nightly_rate_cents": 15000},
        {"room_id": "room-b", "nightly_rate_cents": 17500}
      ]
    }
    """

    # Same content as above with every object's members reordered.
    @reordered_submission """
    {
      "rooms": [
        {"nightly_rate_cents": 15000, "room_id": "room-a"},
        {"nightly_rate_cents": 17500, "room_id": "room-b"}
      ],
      "rate_plan": "flexible",
      "departure_on": "2026-12-13",
      "arrival_on": "2026-12-10",
      "property_id": "ams-canal",
      "guest_id": "guest-22",
      "group_id": "key-group",
      "occurred_on": "2026-10-03",
      "type": "open_group",
      "operation_id": "op-key-order"
    }
    """

    # Members reordered again and the rooms array reversed: array order is
    # significant, so this payload differs from both submissions above.
    @rooms_swapped_submission """
    {
      "rooms": [
        {"nightly_rate_cents": 17500, "room_id": "room-b"},
        {"nightly_rate_cents": 15000, "room_id": "room-a"}
      ],
      "rate_plan": "flexible",
      "departure_on": "2026-12-13",
      "arrival_on": "2026-12-10",
      "property_id": "ams-canal",
      "guest_id": "guest-22",
      "group_id": "key-group",
      "occurred_on": "2026-10-03",
      "type": "open_group",
      "operation_id": "op-key-order"
    }
    """

    test "JSON object key order does not matter", %{conn: conn} do
      conn = post_raw_body(conn, batch(@base_submission))
      assert [%{"status" => "applied", "deposit_due_cents" => 19_500}] = results(conn)

      conn = post_raw_body(conn, batch(@reordered_submission))

      assert [%{"operation_id" => "op-key-order", "status" => "applied"}] = results(conn)

      assert %{"data" => %{"revision" => 1}} =
               get_group(conn, "key-group") |> json_response(200)
    end

    test "array order remains significant", %{conn: conn} do
      conn = post_raw_body(conn, batch(@base_submission))
      assert [%{"status" => "applied"}] = results(conn)

      conn = post_raw_body(conn, batch(@rooms_swapped_submission))

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] = results(conn)
    end

    test "any value difference conflicts and leaves domain state untouched", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000, %{"operation_id" => "op-payment-x"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied", "revision" => 2}] =
               results(conn)

      conflict_variants = [
        payment_operation("group-81", 1001, %{"operation_id" => "op-payment-x"}),
        payment_operation("group-81", 1000, %{
          "operation_id" => "op-payment-x",
          "occurred_on" => "2026-11-02"
        })
      ]

      for variant <- conflict_variants do
        conn = post_operations(conn, [variant])

        assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] = results(conn)
      end

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1000}} =
               get_group(conn, "group-81") |> json_response(200)
    end

    test "an operation missing its identifier is processed but not remembered", %{conn: conn} do
      nameless = %{
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => "ghost-group",
        "amount_cents" => 100
      }

      conn = post_operations(conn, [open_operation(), nameless, nameless])

      assert [
               %{"status" => "applied"},
               %{"operation_id" => nil, "status" => "rejected", "code" => "group_not_found"},
               %{"operation_id" => nil, "status" => "rejected", "code" => "group_not_found"}
             ] = results(conn)

      # Only the operation carrying an identifier was remembered.
      records = Record.list()
      assert length(records) == 1
      assert hd(records).type == "open_group"
    end
  end

  describe "duplicates within one batch" do
    test "an equivalent repeat replays the first result and applies once", %{conn: conn} do
      payment = fn ->
        payment_operation("group-81", 1000, %{"operation_id" => "op-twice"})
      end

      conn =
        post_operations(conn, [open_operation(), payment.(), payment.()])

      assert [
               %{"status" => "applied"},
               second,
               third
             ] = results(conn)

      assert %{"status" => "applied", "revision" => 2, "outstanding_deposit_cents" => 18_500} =
               second

      assert third == second

      assert %{"data" => %{"revision" => 2, "deposit_paid_cents" => 1000}} =
               get_group(conn, "group-81") |> json_response(200)
    end

    test "a conflicting repeat rejects only the later occurrence", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000, %{"operation_id" => "op-clash"}),
          payment_operation("group-81", 2000, %{"operation_id" => "op-clash"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "amount_cents" => 1000},
               %{"status" => "rejected", "code" => "operation_id_conflict"}
             ] = results(conn)

      assert %{"data" => %{"deposit_paid_cents" => 1000}} =
               get_group(conn, "group-81") |> json_response(200)
    end
  end

  describe "GET /api/v1/operations/:operation_id" do
    test "returns the stored result of an applied operation", %{conn: conn} do
      conn =
        post_operations(conn, [open_operation(%{"operation_id" => "op-read-me"})])

      assert [batch_result] = results(conn)

      assert %{"data" => ^batch_result} =
               get_operation(conn, "op-read-me") |> json_response(200)
    end

    test "returns the stored result of a rejected operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_operation("group-81"),
          payment_operation("group-81", 1000, %{
            "operation_id" => "op-late-pay"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               batch_result
             ] = results(conn)

      assert %{"status" => "rejected", "code" => "group_not_active"} = batch_result

      assert %{"data" => ^batch_result} = get_operation(conn, "op-late-pay") |> json_response(200)
    end

    test "unknown identifiers are 404 operation_not_found", %{conn: conn} do
      conn = get_operation(conn, "never-heard-of-it")

      assert json_response(conn, 404) == %{"error" => %{"code" => "operation_not_found"}}
    end

    test "a conflicting reuse never replaces what the endpoint serves", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 1000, %{"operation_id" => "op-original"})
        ])

      assert [_open, original] = results(conn)

      conn =
        post_operations(conn, [
          payment_operation("group-81", 999_999, %{"operation_id" => "op-original"})
        ])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] = results(conn)

      assert %{"data" => ^original} = get_operation(conn, "op-original") |> json_response(200)
    end
  end

  describe "audit retention" do
    test "records keep type, full submission, and first-commit order", %{conn: conn} do
      open_op = open_operation(%{"operation_id" => "op-first"})
      bad_pay = payment_operation("group-81", 99_999, %{"operation_id" => "op-second"})
      move_op = reschedule_operation("group-81", "2026-12-15", %{"operation_id" => "op-third"})

      conn = post_operations(conn, [open_op])
      assert [%{"status" => "applied"}] = results(conn)

      conn = post_operations(conn, [bad_pay])
      assert [%{"status" => "rejected"}] = results(conn)

      conn = post_operations(conn, [move_op])
      assert [%{"status" => "applied"}] = results(conn)

      records = Record.list()

      assert Enum.map(records, & &1.operation_id) == ["op-first", "op-second", "op-third"]

      assert Enum.map(records, & &1.type) == [
               "open_group",
               "record_cash_payment",
               "reschedule_group"
             ]

      assert Jason.decode!(hd(records).submitted_json) == open_op

      rejected_record = Enum.at(records, 1)
      assert Jason.decode!(rejected_record.submitted_json) == bad_pay
      assert Jason.decode!(rejected_record.result_json)["code"] == "payment_exceeds_outstanding"

      # A retry commits nothing new.
      conn = post_operations(conn, [open_op])
      assert [%{"status" => "applied"}] = results(conn)
      assert length(Record.list()) == 3
    end
  end

  describe "unexpected faults" do
    test "an exception rolls back, remembers nothing, and answers 500", %{conn: conn} do
      # A nightly rate whose deposit total overflows SQLite's integer column:
      # parsing accepts any positive integer cents, but persisting the group
      # raises inside the operation transaction.
      assert_error_sent 500, fn ->
        post_operations(conn, [
          open_operation(%{
            "operation_id" => "op-far-future",
            "rooms" => [
              %{"room_id" => "room-far", "nightly_rate_cents" => 100_000_000_000_000_000_000_000}
            ]
          })
        ])
      end

      # Nothing about the faulted operation was remembered or applied.
      assert %{"error" => %{"code" => "operation_not_found"}} =
               get_operation(conn, "op-far-future") |> json_response(404)

      assert %{"error" => %{"code" => "group_not_found"}} =
               get_group(conn, "group-81") |> json_response(404)

      # The service keeps working for later batches.
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] = results(conn)
    end
  end

  describe "concurrent retries" do
    test "identical simultaneous submissions have at-most-once effects", %{conn: context_conn} do
      operation = open_operation(%{"group_id" => "race-group", "operation_id" => "op-race"})

      responses =
        1..4
        |> Enum.map(fn _ ->
          Task.async(fn ->
            post_operations(build_conn(), [operation]) |> json_response(200)
          end)
        end)
        |> Task.await_many(30_000)

      payloads = Enum.map(responses, &hd(&1["results"]))

      # Every gateway response is the same stored result...
      assert length(Enum.uniq(payloads)) == 1
      assert hd(payloads)["status"] == "applied"
      assert hd(payloads)["deposit_due_cents"] == 19_500

      # ...and the domain effect happened exactly once.
      assert %{"data" => %{"revision" => 1}} =
               get_group(context_conn, "race-group") |> json_response(200)

      conn = get_operation(context_conn, "op-race")
      assert %{"data" => data} = json_response(conn, 200)
      assert data == hd(payloads)
    end
  end

  defp batch(operation_json),
    do: ~s({"operations": [#{String.trim(operation_json)}]})

  # Issues one 6600-cent credit lot for guest-22 from a refundable hotel-credit
  # cancellation, matching the standard economics fixture.
  defp issue_standard_lot(conn) do
    conn =
      post_operations(conn, [
        open_operation(),
        payment_operation("group-81", 6000),
        cancel_operation("group-81", %{
          "operation_id" => "op-cancel-standard",
          "occurred_on" => @issue_cancel_on,
          "refund_method" => "hotel_credit"
        })
      ])

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{"status" => "applied", "credit_issued_cents" => 6600}
           ] = results(conn)

    conn
  end

  defp guest_credit(conn, guest_id, on) do
    conn
    |> get_guest_credit(guest_id, on: on)
    |> json_response(200)
    |> Map.fetch!("data")
  end
end
