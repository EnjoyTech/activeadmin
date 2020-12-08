require 'active_admin/router'

module ActiveAdmin
  class StandardLoader

    attr_reader :application

    def initialize(application)
      @application = application
    end

    # Loads all ruby files that are within the load_paths setting.
    # To reload everything simply call `ActiveAdmin.unload!`
    def load!
      unless application.loaded?
        # before_load hook
        application.publish_before_load_event_notification!

        application.files.each{ |file| load file }
        application.initialize_default_namespace

        # after_load hook
        application.publish_after_load_event_notification!

        application.confirm_loaded!
      end
    end

    def routes(rails_router)
      load!
      ActiveAdmin::Router.new(router: rails_router, namespaces: application.namespaces).apply
    end

    # Hook into the Rails code reloading mechanism so that things are reloaded
    # properly in development mode.
    #
    # If any of the app files (e.g. models) has changed, we need to reload all
    # the admin files. If the admin files themselves has changed, we need to
    # regenerate the routes as well.
    def attach_reloader
      Rails.application.config.after_initialize do |app|
        unload_active_admin = -> { ActiveAdmin.application.unload! }

        if app.config.reload_classes_only_on_change
          # Rails is about to unload all the app files (e.g. models), so we
          # should first unload the classes generated by Active Admin, otherwise
          # they will contain references to the stale (unloaded) classes.
          Reloader.to_prepare(prepend: true, &unload_active_admin)
        else
          # If the user has configured the app to always reload app files after
          # each request, so we should unload the generated classes too.
          Reloader.to_complete(&unload_active_admin)
        end

        admin_dirs = {}

        ActiveAdmin.application.load_paths.each do |path|
          admin_dirs[path] = [:rb]
        end

        routes_reloader = app.config.file_watcher.new([], admin_dirs) do
          app.reload_routes!
        end

        app.reloaders << routes_reloader

        Reloader.to_prepare do
          # Rails might have reloaded the routes for other reasons (e.g.
          # routes.rb has changed), in which case Active Admin would have been
          # loaded via the `ActiveAdmin.routes` call in `routes.rb`.
          #
          # Otherwise, we should check if any of the admin files are changed
          # and force the routes to reload if necessary. This would again causes
          # Active Admin to load via `ActiveAdmin.routes`.
          #
          # Finally, if Active Admin is still not loaded at this point, then we
          # would need to load it manually.
          unless ActiveAdmin.application.loaded?
            routes_reloader.execute_if_updated
            ActiveAdmin.application.load!
          end
        end
      end
    end

    private

    def load(file)
      DatabaseHitDuringLoad.capture{ super }
    end

  end
end
