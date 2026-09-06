defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", BatchController, :create
    get "/groups/:group_id", GroupController, :show
    get "/ledger", LedgerController, :show
  end
end
