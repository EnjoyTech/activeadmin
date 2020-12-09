require 'active_admin/reloader'
require 'active_admin/application_settings'
require 'active_admin/namespace_settings'
require 'active_admin/dynamic_loader'
require 'active_admin/standard_loader'

module ActiveAdmin
  class Application

    class << self
      def setting(name, default)
        ApplicationSettings.register name, default
      end

      def inheritable_setting(name, default)
        NamespaceSettings.register name, default
      end
    end

    def settings
      @settings ||= SettingsNode.build(ApplicationSettings)
    end

    def namespace_settings
      @namespace_settings ||= SettingsNode.build(NamespaceSettings)
    end

    def respond_to_missing?(method, include_private = false)
      [settings, namespace_settings].any? { |sets| sets.respond_to?(method) } || super
    end

    def method_missing(method, *args)
      if settings.respond_to?(method)
        settings.send(method, *args)
      elsif namespace_settings.respond_to?(method)
        namespace_settings.send(method, *args)
      else
        super
      end
    end

    attr_reader :namespaces

    delegate :load!, to: :loader

    def initialize
      @namespaces = Namespace::Store.new
    end

    # == Deprecated Settings

    def allow_comments=(*)
      raise "`config.allow_comments` is no longer provided in ActiveAdmin 1.x. Use `config.comments` instead."
    end

    include AssetRegistration

    # Event that gets triggered on load of Active Admin
    BeforeLoadEvent = 'active_admin.application.before_load'.freeze
    AfterLoadEvent  = 'active_admin.application.after_load'.freeze

    def publish_before_load_event_notification!
      ActiveSupport::Notifications.publish BeforeLoadEvent, self
    end

    def publish_after_load_event_notification!
      ActiveSupport::Notifications.publish AfterLoadEvent, self
    end

    def dynamic_loading_enabled?
      return @dynamic_loading_enabled if defined? @dynamic_loading_enabled

      @dynamic_loading_enabled = ENV["USE_AA_DYNAMIC_LOADING"].present? &&
        (Rails.env.development? || Rails.env.test?)
    end

    def loader
      @loader ||= dynamic_loading_enabled? ? DynamicLoader.new(self) : StandardLoader.new(self)
    end

    # Runs before the app's AA initializer
    def setup!
      register_default_assets
    end

    # Runs after the app's AA initializer
    def prepare!
      remove_active_admin_load_paths_from_rails_autoload_and_eager_load
      loader.attach_reloader
    end

    # Registers a brand new configuration for the given resource.
    def register(resource, options = {}, &block)
      ns = options.fetch(:namespace){ default_namespace }
      namespace(ns).register resource, options, &block
    end

    # Creates a namespace for the given name
    #
    # Yields the namespace if a block is given
    #
    # @return [Namespace] the new or existing namespace
    def namespace(name)
      name ||= :root

      namespace = namespaces[name] ||= begin
        namespace = Namespace.new(self, name)
        ActiveSupport::Notifications.publish ActiveAdmin::Namespace::RegisterEvent, namespace
        namespace
      end

      yield(namespace) if block_given?

      namespace
    end

    def initialize_default_namespace
      # init AA resources
      namespace(default_namespace)
    end

    # Register a page
    #
    # @param name [String] The page name
    # @option [Hash] Accepts option :namespace.
    # @&block The registration block.
    #
    def register_page(name, options = {}, &block)
      ns = options.fetch(:namespace){ default_namespace }
      namespace(ns).register_page name, options, &block
    end

    # Whether all configuration files have been loaded
    def loaded?
      @@loaded ||= false
    end

    def confirm_loaded!
      @@loaded = true
    end

    # Removes all defined controllers from memory. Useful in
    # development, where they are reloaded on each request.
    def unload!
      namespaces.each &:unload!
      @@loaded = false
    end

    def ensure_loaded!
      load! unless loaded?
    end

    # Returns ALL the files to be loaded
    def files
      load_paths.flatten.compact.uniq.flat_map{ |path| Dir["#{path}/**/*.rb"] }
    end

    # Used only with dynamic loader (does nothing for standard lodaer) to ensure
    # that certain files are always loaded.
    def ensure_always_loaded(*files)
      loader.ensure_always_loaded(*files) if dynamic_loading_enabled?
    end

    # Creates all the necessary routes for the ActiveAdmin configurations
    #
    # Use this within the routes.rb file:
    #
    #   Application.routes.draw do |map|
    #     ActiveAdmin.routes(self)
    #   end
    #
    # @param rails_router [ActionDispatch::Routing::Mapper]
    def routes(rails_router)
      loader.routes(rails_router)
    end

    # Adds before, around and after filters to all controllers.
    # Example usage:
    #   ActiveAdmin.before_filter :authenticate_admin!
    #
    AbstractController::Callbacks::ClassMethods.public_instance_methods.
      select { |m| m.match(/(filter|action)/) }.each do |name|
      define_method name do |*args, &block|
        controllers_for_filters.each do |controller|
          controller.public_send name, *args, &block
        end
      end
    end

    def controllers_for_filters
      controllers = [BaseController]
      controllers.push *Devise.controllers_for_filters if Dependency.devise?
      controllers
    end

    private

    def register_default_assets
      stylesheets['active_admin.css'] = { media: 'screen' }
      stylesheets['active_admin/print.css'] = { media: 'print' }
      javascripts.add 'active_admin.js'
    end

    # Since app/admin is alphabetically before app/models, we have to remove it
    # from the host app's +autoload_paths+ to prevent missing constant errors.
    #
    # As well, we have to remove it from +eager_load_paths+ to prevent the
    # files from being loaded twice in production.
    def remove_active_admin_load_paths_from_rails_autoload_and_eager_load
      ActiveSupport::Dependencies.autoload_paths -= load_paths
      Rails.application.config.eager_load_paths  -= load_paths
    end

  end
end
