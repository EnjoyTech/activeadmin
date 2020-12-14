# The DynamicProxyRouter enables the ability to blindly replay routes. It is used in
# non-production environment in conjunction with the DynamicLoader to avoid having to
# reload all classes when files are changed. The DynamicLoader can track whether any
# routes could have changed, and if not, it is able to simply replay the routes rather
# than reload all the classes and recalculate them.
#
# To accomplish this, when ActiveAdmin is called to create routes the first time,
# this class can be subbed in for the Rails Router and tracks all instructions to configure
# routes. It can then be replayed immediately against the Rails Router, and then again
# later as needed.
#
# FUTURE TODO: this only exposes ability to diff resource routes, not root routes
module ActiveAdmin
  class DynamicProxyRouter

    # A RouteSet is one "layer" of routing instructions and can contain other RouteSets
    #
    # resources :some_resources, only: [:index, :show] do    # RouteSet 1
    #   member do                                              # RouteSet 2, child of 1
    #     put :action_1                                          # RouteSet 3, child of 2
    #     get :action_2                                          # RouteSet 4, child of 2
    #   end
    #   collection do                                          # RouteSet 5, child of  1
    #     get :action_3                                          # Routeset 6, child of 5
    #   end
    # end
    #
    class RouteSet
      attr_reader :verb, :args, :subroutes, :resource_identifier

      def initialize(verb:, args:, resource_identifier: nil, subroutes: nil)
        @verb = verb
        @args = args
        @resource_identifier = resource_identifier
        @subroutes = subroutes
      end

      def contains_nested_elements?
        # If subroutes is [], the proxy router method_missing picked up something like
        #
        #   collection do
        #     # nothing
        #   end
        #
        # This method needs to return true so that we properly yield (with an empty block)
        # when replaying the routes.
        !subroutes.nil?
      end

      def ==(other)
        verb == other.verb &&
          args == other.args &&
          resource_identifier == other.resource_identifier &&
          subroutes == other.subroutes
      end
    end

    attr_reader :routes, :context, :resource_context, :leaf_count

    def initialize
      @routes = []
      @context = @routes
      @resource_context = nil
      @leaf_count = 0
    end

    # When configuring routes for a resource, the calling codes needs to set the context
    # to that resource so that the DynamicProxyRouter can track what belongs to which
    # resource.
    def set_resource_context(resource, &block)
      @resource_context = resource
      yield
      @resource_context = nil
    end

    # Replay routes against provided router.
    def apply(router:)
      @routes.each do |route_set|
        apply_route_set(router: router, route_set: route_set)
      end
    end

    # Used by DynamicLoader to get the routes for a resource for comparison to determine
    # whether they have changed.
    def route_sets_for(resource)
      resource_identifier = identifier_for(resource)
      @routes.select { |rs| rs.resource_identifier == resource_identifier }
    end

    private

    # Need an identifier for a resource that will be consistent after the class is reloaded.
    def identifier_for(resource)
      return nil if resource.nil?

      resource.is_a?(Resource) ? resource.resource_class_name : resource.name
    end

    # Every route configuration will come through as a method_missing.
    def method_missing(method, *args, &block)
      route_set_params = {
        verb: method,
        args: args,
        resource_identifier: identifier_for(resource_context),
      }

      if block_given?
        old_context = @context
        @context = []

        yield

        old_context << RouteSet.new(route_set_params.merge(subroutes: @context))
        @context = old_context
      else
        @leaf_count += 1
        @context << RouteSet.new(route_set_params)
      end
    end

    # Apply a RouteSet.
    def apply_route_set(router:, route_set:)
      if route_set.contains_nested_elements?
        # deep_dup the args because the router can modify them
        router.send(route_set.verb, *(route_set.args.deep_dup)) do
          route_set.subroutes.each do |sub_route_set|
            apply_route_set(router: router, route_set: sub_route_set)
          end
        end
      else
        # deep_dup the args because the router can modify them
        router.send(route_set.verb.dup, *(route_set.args.deep_dup))
      end
    end
  end
end
