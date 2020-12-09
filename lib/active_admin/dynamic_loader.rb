require 'active_admin/dynamic_proxy_router'
require 'active_admin/router'
require 'active_admin/file_delta_checker'

# When any autoloaded file changes, Rails clears all constants it has autoloaded, and relies
# on const_missing to selectively load what is needed for the request. This strategy does
# not translate over directly to ActiveAdmin due to its needs (building routes, menus, etc).
# Consequently, Active Admin has to be fully reloaded for every dev change rather than
# being able to employ a load-on-undefined-constant strategy.
#
# The DynamicLoader tries to close that gap by adding custom tracking. It relies on an initial
# full load so that it can save the information needed for a Rails reload, and will fall back
# on a full reload in certain circumstances. But once it has the tracking build, it will
# only load resources that have changed to examine whether they need to trigger a full reload,
# and otherwise loads a resource only if one of its pages is visited.
#
# Considerations:
#
# 1) The information within a resource configuration that is needed even when not interacting
#    with that resource are the routes (which also result in the route helper methods that
#    may be used from anywhere) and the menu information. Thus, the DynamicLoader saves this
#    information from each resource on full load. If the resource file hasn't changed, it
#    can safely assume the routes and the menu for that resource haven't changed. If an resource
#    file does change, it reloads that specific file and compares the menu and routing
#    information to what it previously tracked. If either has changed, it will trigger a full
#    reload. Similarly, if an resource file is removed or added, it triggers a full reload.
#
# 2) Any time Rails reloads the dev environment, routes must be regenerated. To do this
#    without reloading all resource files, the DynamicLoader uses the DynamicProxyRouter on a
#    full load to save the routing instructions, which it can then replay as needed. It also
#    leverages this class to do the route comparison mentioned in item #1 when an Active
#    Admin file changes.
#
# 3) If an ActiveAdmin resource hasn't been loaded, the first sign of this will be that
#    the controller isn't loaded, triggering a const_missing on the controller name.
#    During a full load, the DynamicLoader tracks which controller names are associated
#    with each loaded file, allowing it mimic the normal Rails strategy of loading on an
#    as-needed basis based on a const_missing call.
#
# Future TODO: more validation on working with belongs_to and namespsaces
# (belongs_to currently seems to work with if the target (parent) class is set to always load)
# Future TODO: fix to work when multiple files register the same resource.
module ActiveAdmin
  class DynamicLoader

    attr_reader :application, :dynamic_proxy_router
    attr_reader :controller_source_files, :resource_menu_item_options
    attr_reader :file_loaded_at_times

    def initialize(application)
      @application = application
      @controller_source_files ||= {}
      @resource_menu_item_options ||= {}
      @file_loaded_at_times ||= {}
      @always_loaded_files = []
    end

    # Applications can enqueue AA files to always be loaded. The full path name should
    # be provided in order to de-dup effectively. The primary reason for doing this is
    # for a file that is reference by another file's belongs_to statement. It may be
    # helpful in other misc circumstances if there is a dependency on a specific file
    # that DynamicLoader does not know how to handle.
    def ensure_always_loaded(*files)
      @always_loaded_files += files
    end

    # Used to ensure reloader is only attached once.
    def reloader_attached?
      @@reloader_attached ||= false
    end

    # Load all files while tracking controller source files and menu options.
    def load!
      return if application.delay_loading?

      application.unload! # since app may be in partially loaded state, must unload everything first
      @controller_source_files = {}
      @resource_menu_item_options = {}

      log("Full AA load initiated")

      # before_load hook
      application.publish_before_load_event_notification!

      load_all_files_and_save_controller_source_files!
      application.initialize_default_namespace
      save_menu_item_options!

      application.confirm_loaded!

      # after_load hook
      application.publish_after_load_event_notification!

      log("Full AA load complete")
    end

    def load_changed_files_since_last_load!
      return if application.delay_loading?

      file_loaded_at_times.each do |file, last_loaded_at|
        # since loading a file can trigger a full load in some cases, recheck loaded?
        # for each file
        next if application.loaded? || File.mtime(file) < last_loaded_at

        log("Loading modified file #{file} to validate whether full reload is needed")
        load_single_file(file)
      end
    end

    def load_always_loaded_files!
      return if application.delay_loading?

      @always_loaded_files.each do |file|
        log("Loading always-load file #{file}.")
        load_single_file(file)
      end
    end

    # Invoked by Rails during initial load and after file changes. If routes are saved
    # by @dynamic_proxy_router, then replay them. If not, do a full load, save and instantly
    # replay them.
    def routes(rails_router)
      return if application.delay_loading?

      if @dynamic_proxy_router.nil?
        load!

        # save the routes in @dynamic_proxy_router
        @dynamic_proxy_router = DynamicProxyRouter.new
        ActiveAdmin::Router.new(
          router: @dynamic_proxy_router,
          namespaces: application.namespaces,
        ).apply

        log("AA routing calculated")
      end

      @load_start_time = Time.zone.now
      log("Rails-initiated AA routing replay started")
      @dynamic_proxy_router.apply(router: rails_router)
      log(
        "Rails-initiated AA routing replay finished: #{@dynamic_proxy_router.leaf_count} " \
        "leaf routes #{Time.zone.now - @load_start_time} seconds",
      )
    end

    # Force a full and immediate reload of all files due to menu change, route change, etc.
    def force_full_reset!
      return if application.delay_loading?

      log("Full AA reset initiated")

      application.unload!
      # menus normally reset for all changes, but that is bypassed with dynamic loading,
      # so we need to force it here explicitly.
      application.namespaces.each { |n| n.reset_menu!(force_for_dynamic_loading: true) }

      # When routing is invoked for AA, it will load everything if @dynamic_proxy_router is nil.
      @dynamic_proxy_router = nil
      Rails.application.reload_routes!
    end

    # Called from const_missing. If missing constant is a controller with a tracked source
    # file, load the file.
    def attempt_dynamic_load(const_name)
      source_file = controller_source_files[const_name]
      return if source_file.nil?

      log("Loading accessed file #{source_file}.")
      load_single_file(source_file)
    end

    # Load an individual file for whatever reason (changed, accessed when not loaded, etc.)
    def load_single_file(file)
      return if application.delay_loading?

      application.publish_before_load_event_notification!

      clear_file_references(file)
      load_with_controller_tracking(file, trigger_full_reset_if_needed: true)

      application.publish_after_load_event_notification!
    end

    def log(msg)
      return unless ENV["AA_DYNAMIC_LOAD_DEBUG"].present?
      Rails.logger.debug "ACTIVE ADMIN DYNAMIC LOADING: #{Time.zone.now.strftime('%H:%M:%S.%L')}: #{msg}"
    end

    # Prepend the DynamicConstLookupHandler to all namespaces so that it knows how to handle
    # missing controllers and trigger the appropriate load.
    def prepare_namespaces_for_dynamic_loading!
      ActiveAdmin.application.namespaces.each do |namespace|
        mod = (namespace.module_name || 'Object').constantize
        mod.singleton_class.send(:prepend, DynamicConstLookupHandler)
      end
    end

    # Hook into the Rails code reloading mechanism so that things are reloaded
    # properly in development mode.
    def attach_reloader
      Rails.application.config.after_initialize do |app|
        # Unfortunately, the active_admin_datetimepicker gem calls ActiveAdmin.setup,
        # which results in attach reloader getting called twice, which results in
        # this after_initialize block getting called twice, which can result in
        # the reloaders getting attached twice, so explicitly track whether they've
        # been attached to only attach once. This impacts StandardLoader as well,
        # but doesn't really matter in that case since unloading is fast and it
        # has a safety around loading. However, the mechanics of the DynamicLoader
        # are different, and if an AA file was modified, it results in loading it,
        # then a full unload (and then often the same file loaded again since it is the
        # page the user is actually on). So it is worth avoiding here.
        #
        # Thankfully, regardless of the order in which ActiveAdmin.setup is called,
        # after_initialize block isn't actually invoked until a bit later, so it will
        # reliably have the full configuration.
        next if ActiveAdmin.application.loader.reloader_attached?

        # Configure namespaces to handle controller lookup failures.
        ActiveAdmin.application.loader.prepare_namespaces_for_dynamic_loading!

        admin_dirs = ActiveAdmin.application.load_paths.each_with_object({}) do |path, dirs|
          dirs[path] = [:rb]
        end

        # Since ActiveAdmin load paths are excluded from rails regular reload check
        # (see application.rb for why the load paths are removed), we need a custom
        # reloader that will trigger a development reload if they change. Appending
        # it to app.reloaders ensures that any file change in the Active Admin files
        # will result in a Rails development reload. It is "executed" from within the
        # to_prepare just because executing it "catches up" the file time tracking.
        # Because we are dynamically loading, the detection of a file change does not
        # need to do anything other than trigger the Rails development reload.
        #
        # Unlike the standard loader, we don't need to also reload routes, since
        # the dynamic loader separately evalutes route changes and triggers a full
        # reset if they are detected.
        changed_config_reloader = app.config.file_watcher.new([], admin_dirs) do
          # do nothing, just needs to trigger dependency clearing
        end
        app.reloaders << changed_config_reloader

        # If an ActiveAdmin file is added or removed, trigger a full reset since the
        # routes and menus need to be fully re-evaluated.
        #
        # This reloader does not need to be added to app.reloaders because file additions
        # and removals will already trigger the changed_config_reloader. It is just
        # used to control action within the to_prepare block.
        delta_config_reloader = FileDeltaChecker.new(admin_dirs) do
          ActiveAdmin.application.loader.log(
            "Full reset initiated due to ActiveAdmin file delta (added or removed file)",
          )
          ActiveAdmin.application.loader.force_full_reset!
        end

        # Rails has just unloaded all the app files, so Active Admin needs to also unload
        # the classes generated by Active Admin, otherwise they will contain references to the
        # stale (unloaded) classes.
        Reloader.to_prepare(prepend: true) do
          ActiveAdmin.application.loader.log(
            "Rails-initiated reload - unloading AA and depending on dynamic reloading as needed",
          )
          ActiveAdmin.application.unload!

          # Executing doesn't have side effect since the block provided was empty but it does
          # update the internal tracking of the reloader times.
          changed_config_reloader.execute_if_updated

          if delta_config_reloader.delta?
            # Force a full reset if there are any Active Admin file additions/removals.
            delta_config_reloader.execute
          else
            # Load the files that should always be loaded.
            ActiveAdmin.application.loader.load_always_loaded_files!

            # Load any changed files explicitly in case they trigger a full reload due to menu
            # changes, route changes, etc.
            ActiveAdmin.application.loader.load_changed_files_since_last_load!
          end
        end

        @@reloader_attached = true
      end
    end

    private

    def all_resources
      ActiveAdmin.application.namespaces.map(&:resources).flat_map(&:values)
    end

    def clear_file_references(file)
      controller_source_files.select { |c, f| f == file }.each do |c, f|
        controller_source_files.delete(c)
      end
    end

    def identifier_for(resource)
      resource.is_a?(Resource) ? resource.resource_class_name : resource.name
    end

    def load(file)
      load_time = Time.zone.now
      DatabaseHitDuringLoad.capture{ super }
      file_loaded_at_times[file] = load_time
    end

    def load_with_controller_tracking(file, trigger_full_reset_if_needed: false)
      added_resources = capture_added_resources { load file }

      added_resources.each do |resource|
        controller_source_files[resource.controller.name] = file
      end

      return unless trigger_full_reset_if_needed

      added_resources.each do |resource|
        temp_dynamic_proxy_router = DynamicProxyRouter.new
        Router.new(
          router: temp_dynamic_proxy_router,
          namespaces: ActiveAdmin.application.namespaces,
        ).apply_resource(resource)

        if temp_dynamic_proxy_router.route_sets_for(resource) !=
            dynamic_proxy_router&.route_sets_for(resource)
          log("Determined full AA reset needed due to route change in #{file}")
          force_full_reset!
        elsif resource_menu_item_options[identifier_for(resource)] != menu_item_options_for(resource)
          log("Determined full AA reset needed due to menu change in #{file}")
          force_full_reset!
        end
      end
    end

    def load_all_files_and_save_controller_source_files!
      # load @always_loaded_files first as other files may depend on them
      (@always_loaded_files + application.files).uniq.each do |file|
        load_with_controller_tracking(file)
      end
    end

    def menu_item_options_for(resource)
      provided_options = resource.provided_menu_options
      return provided_options unless provided_options.is_a?(Hash)

      # procs aren't comparable, so take the source locations as a proxy
      options = provided_options.deep_dup
      options.each do |option, value|
        options[option] = value.source_location if value.is_a?(Proc)
      end
      options
    end

    def save_menu_item_options!
      application.namespaces.each do |namespace|
        namespace.resources.each do |resource|
          # parent arg seems to get removed later so do a deep dup
          resource_menu_item_options[identifier_for(resource)] = menu_item_options_for(resource)
        end
        # initialize the menus so that menu info is saved before any unloading occurs (menu
        # information is saved within the menu classes until reset/updated)
        namespace.menus.send(:build_menus!)
      end
    end

    # Detects and returns what resources were added during the provided block.
    def capture_added_resources(&block)
      resources_before = all_resources
      yield
      all_resources - resources_before
    end

    # This module gets prepended to the AA namespaces to add the functionality to dynamically
    # load files based on a missing controller constant.
    module DynamicConstLookupHandler
      def const_missing(const_name)
        begin
          super(const_name)
        rescue NameError => e
          # we are trying to catch:
          # self.name == 'Admin'
          # const_name == 'XxxController'
          full_const_name = [self.name, const_name].join('::')
          ActiveAdmin.application.loader.attempt_dynamic_load(full_const_name)
          return const_get(const_name) if const_defined?(const_name)
          super(const_name)
        end
      end
    end
  end
end
