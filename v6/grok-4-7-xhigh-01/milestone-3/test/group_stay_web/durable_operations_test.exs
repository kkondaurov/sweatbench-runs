defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  import Ecto.Query

  setup %{conn: conn} do
    on_exit(fn -> Application.delete_env(:group_stay, :operation_fault) end)
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  test "retries an equivalent payload verbatim and does not touch domain state", %{conn: conn} do
    op =
      open_op("g", %{
        "operation_id" => "op/1001",
        "note" => "desk",
        "rooms" => [
          %{"nightly_rate_cents" => 100, "room_id" => "a", "bed" => "king"},
          %{"room_id" => "b", "nightly_rate_cents" => 200}
        ]
      })

    {conn, first} = one(conn, op)
    assert first["status"] == "applied"
    assert first["revision"] == 1

    reordered = %{
      "rooms" => [
        %{"bed" => "king", "room_id" => "a", "nightly_rate_cents" => 100},
        %{"nightly_rate_cents" => 200, "room_id" => "b"}
      ],
      "note" => "desk",
      "rate_plan" => op["rate_plan"],
      "departure_on" => op["departure_on"],
      "arrival_on" => op["arrival_on"],
      "property_id" => op["property_id"],
      "guest_id" => op["guest_id"],
      "group_id" => op["group_id"],
      "occurred_on" => op["occurred_on"],
      "type" => op["type"],
      "operation_id" => op["operation_id"]
    }

    Repo.delete_all(Room)
    Repo.delete_all(Group)

    {conn, replay} = one(conn, reordered)
    assert replay == first
    assert get(conn, "/api/v1/groups/g") |> json_response(404)

    assert json_response(get(conn, "/api/v1/operations/op/1001"), 200) == %{"data" => first}
    refute Map.has_key?(json_response(get(conn, "/api/v1/operations/op/1001"), 200), "submission")
  end

  test "a different payload conflicts and leaves the original record", %{conn: conn} do
    {conn, original} = one(conn, open_op("g", %{"operation_id" => "op-1", "note" => "first"}))
    before = audit("op-1")

    {conn, conflict} =
      one(conn, open_op("other", %{"operation_id" => "op-1", "note" => "second"}))

    assert conflict == %{
             "operation_id" => "op-1",
             "status" => "rejected",
             "code" => "operation_id_conflict"
           }

    assert get(conn, "/api/v1/groups/other") |> json_response(404)
    assert group(conn, "g")["revision"] == 1
    assert json_response(get(conn, "/api/v1/operations/op-1"), 200) == %{"data" => original}
    assert audit("op-1") == before
    assert Repo.aggregate(Record, :count) == 1
  end

  test "array order is a different payload and numeric types are not coerced", %{conn: conn} do
    rooms = [
      %{"room_id" => "a", "nightly_rate_cents" => 100},
      %{"room_id" => "b", "nightly_rate_cents" => 200}
    ]

    {conn, _} = one(conn, open_op("g", %{"operation_id" => "rooms", "rooms" => rooms}))

    {conn, swapped} =
      one(
        conn,
        open_op("g", %{
          "operation_id" => "rooms",
          "rooms" => Enum.reverse(rooms)
        })
      )

    assert swapped["code"] == "operation_id_conflict"

    assert group(conn, "g")["rooms"] == [
             %{"room_id" => "a", "nightly_rate_cents" => 100},
             %{"room_id" => "b", "nightly_rate_cents" => 200}
           ]

    {conn, _} = one(conn, payment_op("g", 10, %{"operation_id" => "pay"}))

    body =
      ~s({"operations":[{"type":"record_cash_payment","operation_id":"pay","occurred_on":"2026-10-04","group_id":"g","amount_cents":10.0}]})

    conn = post_raw(conn, body)
    [conflict] = json_response(conn, 200)["results"]
    assert conflict["code"] == "operation_id_conflict"
    assert group(conn, "g")["deposit_paid_cents"] == 10
    assert group(conn, "g")["revision"] == 2
  end

  test "null and omitted fields are different payloads", %{conn: conn} do
    {conn, _} = one(conn, open_op("g"))
    {conn, paid} = one(conn, payment_op("g", 25, %{"operation_id" => "pay"}))

    {conn, conflict} =
      one(conn, payment_op("g", 25, %{"operation_id" => "pay", "expected_revision" => nil}))

    assert conflict["code"] == "operation_id_conflict"
    assert group(conn, "g")["revision"] == 2
    assert json_response(get(conn, "/api/v1/operations/pay"), 200)["data"] == paid
  end

  test "remembers rejections and does not apply a corrected retry", %{conn: conn} do
    missing = %{
      "operation_id" => "later-valid",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "g",
      "amount_cents" => 10
    }

    {conn, rejected} = one(conn, missing)
    assert rejected["code"] == "group_not_found"

    {conn, _} = one(conn, open_op("g"))
    {conn, again} = one(conn, missing)
    assert again == rejected
    assert group(conn, "g")["deposit_paid_cents"] == 0
    assert group(conn, "g")["revision"] == 1

    corrected =
      missing
      |> Map.put("operation_id", "later-valid")
      |> Map.put("amount_cents", 11)

    {conn, conflict} = one(conn, corrected)
    assert conflict["code"] == "operation_id_conflict"
    assert group(conn, "g")["deposit_paid_cents"] == 0

    {_conn, fresh} = one(conn, payment_op("g", 11, %{"operation_id" => "fresh"}))
    assert fresh["status"] == "applied"
  end

  test "a stale result is returned verbatim after the group moves on", %{conn: conn} do
    {conn, _} = one(conn, open_op("g"))
    {conn, _} = one(conn, payment_op("g", 100, %{"operation_id" => "first"}))

    stale =
      payment_op("g", 50, %{
        "operation_id" => "stale",
        "expected_revision" => 1,
        "amount_cents" => -5
      })

    {conn, rejected} = one(conn, stale)

    assert rejected == %{
             "operation_id" => "stale",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "g",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    {conn, _} = one(conn, payment_op("g", 20, %{"operation_id" => "second"}))
    assert group(conn, "g")["revision"] == 3

    {conn, replay} = one(conn, stale)
    assert replay == rejected
    assert group(conn, "g")["deposit_paid_cents"] == 120
    assert group(conn, "g")["revision"] == 3

    corrected = Map.put(stale, "expected_revision", 3)
    {conn, conflict} = one(conn, corrected)
    assert conflict["code"] == "operation_id_conflict"
    assert group(conn, "g")["revision"] == 3
    assert json_response(get(conn, "/api/v1/operations/stale"), 200) == %{"data" => rejected}
  end

  test "keeps going after a conflict and a remembered rejection", %{conn: conn} do
    {conn, results} =
      batch(conn, [
        open_op("g", %{"operation_id" => "open"}),
        open_op("other", %{"operation_id" => "open"}),
        %{"operation_id" => "bad", "type" => "mystery", "occurred_on" => "2026-10-03"},
        open_op("later", %{"operation_id" => "later"})
      ])

    assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "rejected", "applied"]
    assert Enum.at(results, 1)["code"] == "operation_id_conflict"
    assert Enum.at(results, 2)["code"] == "invalid_operation"
    assert group(conn, "later")["group_id"] == "later"

    assert json_response(get(conn, "/api/v1/operations/bad"), 200)["data"]["code"] ==
             "invalid_operation"
  end

  test "stores type, full submission, and first-commit order", %{conn: conn} do
    {conn, _} =
      one(
        conn,
        open_op("g", %{"operation_id" => "a", "note" => "keep", "expected_revision" => 9})
      )

    {conn, _} =
      one(conn, %{
        "operation_id" => "b",
        "type" => "mystery",
        "occurred_on" => "2026-10-03",
        "extra" => [%{"z" => 1, "a" => 2}, 3]
      })

    {conn, _} = one(conn, payment_op("g", 5, %{"operation_id" => "c"}))
    {conn, _} = one(conn, payment_op("g", 5, %{"operation_id" => "c"}))
    {_conn, _} = one(conn, payment_op("g", 1, %{"operation_id" => "d"}))

    records = Repo.all(from r in Record, order_by: [asc: r.id])
    assert Enum.map(records, & &1.operation_id) == ["a", "b", "c", "d"]

    assert Enum.map(records, & &1.type) == [
             "open_group",
             "mystery",
             "record_cash_payment",
             "record_cash_payment"
           ]

    [first, second | _] = records
    submission = Jason.decode!(first.submission)
    assert submission["note"] == "keep"
    assert submission["expected_revision"] == 9
    assert submission["rooms"] |> Enum.map(& &1["room_id"]) == ["room-a", "room-b"]
    assert Jason.decode!(second.submission)["extra"] == [%{"z" => 1, "a" => 2}, 3]
    assert second.type == "mystery"

    ids = Enum.map(records, & &1.id)
    assert ids == Enum.sort(ids)
    assert length(Enum.uniq(ids)) == 4
  end

  test "remembers an incomplete operation and does not record an unusable id", %{conn: conn} do
    {conn, results} =
      batch(conn, [
        %{"operation_id" => "partial", "type" => 1},
        %{"operation_id" => 12, "type" => "open_group", "occurred_on" => "2026-10-03"},
        "not-a-map"
      ])

    assert Enum.map(results, & &1["code"]) == [
             "invalid_operation",
             "invalid_operation",
             "invalid_operation"
           ]

    assert json_response(get(conn, "/api/v1/operations/partial"), 200)["data"] ==
             Enum.at(results, 0)

    record = Repo.get_by!(Record, operation_id: "partial")
    assert record.type == nil
    assert Jason.decode!(record.submission) == %{"operation_id" => "partial", "type" => 1}
    assert Repo.get_by(Record, operation_id: "12") == nil

    assert json_response(get(conn, "/api/v1/operations/missing"), 404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "credit and cancellation retries do not settle twice", %{conn: conn} do
    {conn, _} = one(conn, open_op("source", %{"guest_id" => "guest-credit"}))
    {conn, _} = one(conn, payment_op("source", 100))

    {conn, issued} =
      one(
        conn,
        cancel_op("source", %{
          "operation_id" => "issue",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      )

    {conn, replay_issue} =
      one(
        conn,
        cancel_op("source", %{
          "refund_method" => "hotel_credit",
          "occurred_on" => "2026-11-01",
          "operation_id" => "issue"
        })
      )

    assert replay_issue == issued
    assert credit(conn, "guest-credit")["available_cents"] == 110
    assert ledger(conn)["data"]["cash_converted_to_credit_cents"] == 100
    assert ledger(conn)["data"]["credit_liability_cents"] == 110

    {conn, _} = one(conn, open_op("next", %{"guest_id" => "guest-credit"}))

    short = credit_op("next", 200, %{"operation_id" => "short"})
    {conn, short_result} = one(conn, short)
    assert short_result["code"] == "insufficient_credit"

    {conn, _} =
      one(conn, open_op("more", %{"guest_id" => "guest-credit", "operation_id" => "more-open"}))

    {conn, _} = one(conn, payment_op("more", 200, %{"operation_id" => "more-pay"}))

    {conn, _} =
      one(
        conn,
        cancel_op("more", %{
          "operation_id" => "more-cancel",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      )

    assert credit(conn, "guest-credit")["available_cents"] == 330

    {conn, still_short} = one(conn, short)
    assert still_short == short_result
    assert group(conn, "next")["credit_paid_cents"] == 0
    assert credit(conn, "guest-credit")["available_cents"] == 330

    applied = credit_op("next", 50, %{"operation_id" => "use"})
    {conn, used} = one(conn, applied)
    assert used["status"] == "applied"
    {conn, used_again} = one(conn, applied)
    assert used_again == used
    assert group(conn, "next")["credit_paid_cents"] == 50
    assert group(conn, "next")["revision"] == 2
    assert credit(conn, "guest-credit")["available_cents"] == 280
  end

  test "a non-refundable credit request stays rejected after the stay becomes refundable", %{
    conn: conn
  } do
    {conn, _} = one(conn, open_op("g"))
    {conn, _} = one(conn, payment_op("g", 80))

    late =
      cancel_op("g", %{
        "operation_id" => "late-credit",
        "occurred_on" => "2026-12-09",
        "refund_method" => "hotel_credit"
      })

    {conn, rejected} = one(conn, late)
    assert rejected["code"] == "refund_method_not_available"
    assert group(conn, "g")["status"] == "active"
    assert group(conn, "g")["revision"] == 2

    {conn, _} = one(conn, reschedule_op("g", "2027-06-01", %{"operation_id" => "move"}))
    {conn, again} = one(conn, late)
    assert again == rejected
    assert group(conn, "g")["status"] == "active"

    {_conn, applied} =
      one(
        conn,
        cancel_op("g", %{
          "operation_id" => "fresh-credit",
          "occurred_on" => "2026-12-09",
          "refund_method" => "hotel_credit"
        })
      )

    assert applied["status"] == "applied"
    assert applied["credit_issued_cents"] == 88
  end

  test "an unexpected fault rolls back the operation, returns 500, and can be retried", %{
    conn: conn
  } do
    Application.put_env(:group_stay, :operation_fault, fn op ->
      if op["operation_id"] == "boom" do
        {:ok, _group} =
          Groups.create(
            %{
              group_id: "fault-group",
              guest_id: "guest-22",
              property_id: "ams-canal",
              booked_on: ~D[2026-10-03],
              arrival_on: ~D[2026-12-10],
              departure_on: ~D[2026-12-13],
              rate_plan: "flexible",
              lodging_total_cents: 1,
              deposit_due_cents: 1
            },
            [%{room_id: "room-a", nightly_rate_cents: 1}]
          )

        raise "forced operation fault"
      end
    end)

    assert_error_sent 500, fn ->
      post_batch(conn, [
        open_op("kept", %{"operation_id" => "kept"}),
        payment_op("kept", 10, %{"operation_id" => "boom"}),
        open_op("skipped", %{"operation_id" => "skipped"})
      ])
    end

    assert group(conn, "kept")["revision"] == 1
    assert group(conn, "kept")["deposit_paid_cents"] == 0
    assert get(conn, "/api/v1/groups/skipped") |> json_response(404)
    assert get(conn, "/api/v1/groups/fault-group") |> json_response(404)
    assert json_response(get(conn, "/api/v1/operations/kept"), 200)["data"]["status"] == "applied"

    assert json_response(get(conn, "/api/v1/operations/boom"), 404)["error"]["code"] ==
             "operation_not_found"

    assert Repo.get_by(Record, operation_id: "skipped") == nil

    Application.delete_env(:group_stay, :operation_fault)

    {conn, results} =
      batch(conn, [
        open_op("kept", %{"operation_id" => "kept"}),
        payment_op("kept", 10, %{"operation_id" => "boom"}),
        open_op("skipped", %{"operation_id" => "skipped"})
      ])

    assert Enum.at(results, 0)["revision"] == 1
    assert Enum.at(results, 1)["status"] == "applied"
    assert Enum.at(results, 1)["outstanding_deposit_cents"] == 19490
    assert Enum.at(results, 2)["status"] == "applied"
    assert group(conn, "kept")["deposit_paid_cents"] == 10
    assert group(conn, "kept")["revision"] == 2
  end

  test "raw key order is an equivalent retry", %{conn: conn} do
    first =
      ~s({"operations":[{"operation_id":"raw-1","type":"open_group","occurred_on":"2026-10-03","group_id":"raw","guest_id":"guest-22","property_id":"ams-canal","arrival_on":"2026-12-10","departure_on":"2026-12-11","rate_plan":"flexible","rooms":[{"room_id":"a","nightly_rate_cents":100}]}]})

    second =
      ~s({"operations":[{"rooms":[{"nightly_rate_cents":100,"room_id":"a"}],"rate_plan":"flexible","departure_on":"2026-12-11","arrival_on":"2026-12-10","property_id":"ams-canal","guest_id":"guest-22","group_id":"raw","occurred_on":"2026-10-03","type":"open_group","operation_id":"raw-1"}]})

    conn = post_raw(conn, first)
    [opened] = json_response(conn, 200)["results"]
    conn = post_raw(conn, second)
    [replay] = json_response(conn, 200)["results"]
    assert replay == opened
    assert group(conn, "raw")["revision"] == 1
    assert Repo.aggregate(Record, :count) == 1
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp post_raw(conn, body) do
    conn
    |> recycle()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", body)
  end

  defp batch(conn, operations) do
    conn = post_batch(conn, operations)
    {conn, json_response(conn, 200)["results"]}
  end

  defp one(conn, operation) do
    {conn, [result]} = batch(conn, [operation])
    {conn, result}
  end

  defp group(conn, group_id) do
    json_response(get(conn, "/api/v1/groups/#{group_id}"), 200)["data"]
  end

  defp ledger(conn) do
    json_response(get(conn, "/api/v1/ledger"), 200)
  end

  defp credit(conn, guest_id) do
    json_response(get(conn, "/api/v1/guests/#{guest_id}/credit"), 200)["data"]
  end

  defp audit(operation_id) do
    record = Repo.get_by!(Record, operation_id: operation_id)

    %{
      id: record.id,
      type: record.type,
      submission: record.submission,
      result: record.result,
      inserted_at: record.inserted_at,
      updated_at: record.updated_at
    }
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-#{group_id}-#{amount}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp credit_op(group_id, amount, overrides) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}-#{amount}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-06",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reschedule_op(group_id, new_arrival, overrides) do
    Map.merge(
      %{
        "operation_id" => "move-#{group_id}",
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-05",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival
      },
      overrides
    )
  end

  defp cancel_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id
      },
      overrides
    )
  end
end
