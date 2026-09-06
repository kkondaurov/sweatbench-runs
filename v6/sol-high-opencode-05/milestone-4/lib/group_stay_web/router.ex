defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", ApiController, :submit_batch
    get "/operations/:operation_id", ApiController, :show_operation
    get "/payments/:payment_operation_id", ApiController, :show_payment
    get "/groups/:group_id", ApiController, :show_group
    get "/guests/:guest_id/credit", ApiController, :guest_credit
    get "/ledger", ApiController, :ledger
  end
end
