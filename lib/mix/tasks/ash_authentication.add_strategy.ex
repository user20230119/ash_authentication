# credo:disable-for-this-file Credo.Check.Design.AliasUsage
defmodule Mix.Tasks.AshAuthentication.AddStrategy do
  use Igniter.Mix.Task

  @example "mix ash_authentication.add_strategy password"

  @shortdoc "Adds the provided strategy or strategies to your user resource"

  @strategies [password: "Register and sign in with a username/email and a password."]

  @strategy_explanation Enum.map_join(@strategies, "\n", fn {name, description} ->
                          "  * `#{name}` - #{description}"
                        end)

  @strategy_names @strategies |> Keyword.keys() |> Enum.map(&to_string/1)

  @moduledoc """
  #{@shortdoc}

  This task will add the provided strategy or strategies to your user resource.

  The following strategies are available. For all others, see the relevant documentation for setup

  #{@strategy_explanation}

  ## Example

  ```bash
  #{@example}
  ```

  ## Options

  * `--user`, `-u` -  The user resource. Defaults to `YourApp.Accounts.User`
  * `--identity-field`, `-i` - The field on the user resource that will be used to identify
    the user. Defaults to `email`
  """

  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      example: @example,
      extra_args?: false,
      # A list of environments that this should be installed in, only relevant if this is an installer.
      only: nil,
      # a ist of positional arguments, i.e `[:file]`
      positional: [
        strategies: [rest: true]
      ],
      schema: [
        user: :string
      ],
      aliases: [
        u: :user
      ]
    }
  end

  def igniter(igniter, argv) do
    {%{strategies: strategies}, argv} = positional_args!(argv)
    default_user = Igniter.Project.Module.module_name(igniter, "Accounts.User")

    options =
      argv
      |> options!()
      |> Keyword.update(:identity_field, :email, &String.to_atom/1)
      |> Keyword.update(:user, default_user, &Igniter.Code.Module.parse/1)

    if invalid_strategy = Enum.find(strategies, &(&1 not in @strategy_names)) do
      Mix.shell().error("""
      Invalid strategy provided: `#{invalid_strategy}`

      Not all strategies can be installed using `ash_authentication.add_strategy` yet.
      Want to see a strategy added? Open an issue (or even better, a PR!) on GitHub.

      See a list of strategies and how to install them here:

      https://hexdocs.pm/ash_authentication/get-started.html

      Available Strategies:

      #{@strategy_explanation}
      """)

      exit({:shutdown, 1})
    end

    case Igniter.Project.Module.module_exists(igniter, options[:user]) do
      {true, igniter} ->
        Enum.reduce(strategies, igniter, fn "password", igniter ->
          password(igniter, options)
        end)

      {false, igniter} ->
        Igniter.add_issue(igniter, """
        User module #{inspect(options[:user])} was not found.

        Perhaps you have not yet installed ash_authentication?
        """)
    end
  end

  defp password(igniter, options) do
    sender = Module.concat(options[:user], Senders.SendPasswordResetEmail)

    igniter
    |> Igniter.Project.Deps.add_dep({:bcrypt_elixir, "~> 3.0"})
    |> Ash.Resource.Igniter.add_new_attribute(options[:user], options[:identity_field], """
    attribute :#{options[:identity_field]}, :ci_string do
      allow_nil? false
      public? true
    end
    """)
    |> Ash.Resource.Igniter.add_new_attribute(options[:user], :hashed_password, """
    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end
    """)
    |> Ash.Resource.Igniter.add_new_identity(
      options[:user],
      :"unique_#{options[:identity_field]}",
      """
      identity :unique_#{options[:identity_field]}, [:#{options[:identity_field]}]
      """
    )
    |> AshAuthentication.Igniter.add_new_strategy(options[:user], :password, :password, """
    password :password do
      identity_field :#{options[:identity_field]}

      resettable do
        sender #{inspect(sender)}
      end
    end
    """)
    |> generate_sign_in_and_registration(options)
    |> generate_reset(sender, options)
    |> Ash.Igniter.codegen("add_password_authentication")
  end

  defp generate_reset(igniter, sender, options) do
    igniter
    |> create_reset_sender(sender, options)
    |> Ash.Resource.Igniter.add_new_action(options[:user], :request_password_reset, """
    action :request_password_reset do
      description "Send password reset instructions to a user if they exist."

      argument :#{options[:identity_field]}, :ci_string do
        allow_nil? false
      end

      # creates a reset token and invokes the relevant senders
      run {AshAuthentication.Strategy.Password.RequestPasswordReset, action: :get_by_#{options[:identity_field]}}
    end
    """)
    |> Ash.Resource.Igniter.add_new_action(
      options[:user],
      :"get_by_#{options[:identity_field]}",
      """
      read :get_by_#{options[:identity_field]} do
        description "Looks up a user by their #{options[:identity_field]}"
        get? true

        argument :#{options[:identity_field]}, :ci_string do
          allow_nil? false
        end

        filter expr(#{options[:identity_field]} == ^arg(:#{options[:identity_field]}))
      end
      """
    )
    |> Ash.Resource.Igniter.add_new_action(options[:user], :reset_password, """
    update :reset_password do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints [min_length: 8]
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end
    """)
  end

  defp create_reset_sender(igniter, sender, options) do
    web_module = Igniter.Libs.Phoenix.web_module(igniter)
    {web_module_exists?, igniter} = Igniter.Project.Module.module_exists(igniter, web_module)

    use_web_module =
      if web_module_exists? do
        "use #{inspect(web_module)}, :verified_routes"
      end

    example_domain = options[:user] |> Module.split() |> :lists.droplast() |> Module.concat()

    real_example =
      if web_module_exists? do
        """
        # Example of how you might send this email
        # #{inspect(example_domain)}.Emails.send_password_reset_email(
        #   user,
        #   token
        # )
        """
      end

    Igniter.Project.Module.create_module(
      igniter,
      sender,
      ~s'''
      @moduledoc """
      Sends a password reset email
      """

      use AshAuthentication.Sender
      #{use_web_module}

      @impl true
      def send(_user, token, _) do
        #{real_example}
        IO.puts("""
        Click this link to reset your password:

        \#{url(~p"/password-reset/\#{token}")}
        """)
      end
      '''
    )
  end

  defp generate_sign_in_and_registration(igniter, options) do
    igniter
    |> Ash.Resource.Igniter.add_new_action(options[:user], :sign_in_with_password, """
    read :sign_in_with_password do
      description "Attempt to sign in using a #{options[:identity_field]} and password."
      get? true

      argument :#{options[:identity_field]}, :ci_string do
        description "The #{options[:identity_field]} to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      # validates the provided #{options[:identity_field]} and password and generates a token
      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end
    """)
    |> Ash.Resource.Igniter.add_new_action(options[:user], :sign_in_with_token, """
    read :sign_in_with_token do
      # In the generated sign in components, we generate a validate the
      # #{options[:identity_field]} and password directly in the LiveView
      # and generate a short-lived token that can be used to sign in over
      # a standard controller action, exchanging it for a standard token.
      # This action performs that exchange. If you do not use the generated
      # liveviews, you may remove this action, and set
      # `sign_in_tokens_enabled? false` in the password strategy.

      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      # validates the provided sign in token and generates a token
      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end
    """)
    |> Ash.Resource.Igniter.add_new_action(options[:user], :register_with_password, """
    create :register_with_password do
      description "Register a new user with a #{options[:identity_field]} and password."
      accept [:#{options[:identity_field]}]

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints [min_length: 8]
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end
    """)
  end
end
