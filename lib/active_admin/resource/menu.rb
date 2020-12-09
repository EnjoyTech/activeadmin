module ActiveAdmin
  class Resource
    module Menu

      # Set the menu options.
      # To disable this menu item, call `menu(false)` from the DSL
      def menu_item_options=(options)
        @provided_menu_options = options

        if options == false
          @include_in_menu = false
          @menu_item_options = {}
        else
          @include_in_menu = true
          @navigation_menu_name = options[:menu_name]
          @menu_item_options = default_menu_options.merge options
        end
      end

      def menu_item_options
        @menu_item_options ||= default_menu_options
      end

      def provided_menu_options
        @provided_menu_options
      end

      def default_menu_options
        if ActiveAdmin.application.dynamic_loading_enabled?
          # If using dynamic loading, it is important that the menu options not contain
          # any references to classes that will be reloaded, such as the resource or
          # underlying model.
          #
          # This is messy and deserves some more attention. The procs are essentially
          # the same as the non-dynamic-loading procs below, but were determined by
          # following the code path to get to code that is independent of a (potentially
          # stale) resource.
          #
          # For the if: authorization, by constantizing in the proc, it will find the up-to-date
          # version of the class.

          # These local variables are accessible to the procs.
          menu_resource_class_name = respond_to?(:resource_class) ? resource_class.name : self
          needs_constantize = respond_to?(:resource_class)
          menu_item_path = route_builder.collection_path_name
          menu_item_param_names = route_builder.send(:route_collection_param_names)

          {
            id:    resource_name.plural,
            label: plural_resource_label,
            url:   proc {
              menu_item_params = menu_item_param_names.map { |p| params[p] }
              Helpers::Routes.public_send menu_item_path, *menu_item_params, url_options
            },
            if:    proc {
              authorized?(
                Auth::READ,
                needs_constantize ? menu_resource_class_name.constantize : menu_resource_class_name,
              )
            },
          }
        else
          # These local variables are accessible to the procs.
          menu_resource_class = respond_to?(:resource_class) ? resource_class : self
          resource = self

          {
            id: resource_name.plural,
            label: proc { resource.plural_resource_label },
            url: proc { resource.route_collection_path(params, url_options) },
            if: proc { authorized?(Auth::READ, menu_resource_class) }
          }
        end
      end

      def navigation_menu_name=(menu_name)
        self.menu_item_options = { menu_name: menu_name }
      end

      def navigation_menu_name
        case @navigation_menu_name ||= DEFAULT_MENU
        when Proc
          controller.instance_exec(&@navigation_menu_name).to_sym
        else
          @navigation_menu_name
        end
      end

      def navigation_menu
        namespace.fetch_menu(navigation_menu_name)
      end

      def add_to_menu(menu_collection)
        if include_in_menu?
          @menu_item = menu_collection.add navigation_menu_name, menu_item_options
        end
      end

      attr_reader :menu_item

      # Should this resource be added to the menu system?
      def include_in_menu?
        @include_in_menu != false
      end

    end
  end
end
