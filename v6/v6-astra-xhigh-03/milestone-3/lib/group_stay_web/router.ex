defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", PartnerBatchController, :create
    get "/operations/:operation_id", OperationController, :show
    get "/groups/:group_id", GroupController, :show
    get "/ledger", LedgerController, :show
    get "/guests/:guest_id/credit", CreditController, :show
  end
end
