require 'rails_helper'

RSpec.describe ActiveAdmin::DynamicProxyRouter do

  let(:dynamic_proxy_router) { described_class.new }
  let(:router) { double :router }

  describe "#apply" do

    subject { dynamic_proxy_router.apply(router: router) }

    context "for a single route" do
      before do
        dynamic_proxy_router.get '/some_url' => 'some_controller#some_action'
      end

      it "replays route successfully" do
        expect(router).to receive(:get).with('/some_url' => 'some_controller#some_action')
        subject
      end
    end

    # This spec doesn't test the nested nature (i.e. that the 2nd call to router occurs
    # while yielding from the first). I can't figure out how to do that, but this is better
    # than nothing.
    context "for a nested route" do
      before do
        dynamic_proxy_router.resources :some_resources, only: [:index, :show] do
          dynamic_proxy_router.member do
            dynamic_proxy_router.put :some_action
          end
        end
        dynamic_proxy_router.get '/some_url' => 'some_controller#some_action'
      end

      it "replays route successfully" do
        expect(router)
          .to receive(:resources)
          .with(:some_resources, only: [:index, :show])
          .and_yield
        expect(router)
          .to receive(:member)
          .with(no_args)
          .and_yield
        expect(router).to receive(:put).with(:some_action)
        expect(router).to receive(:get).with('/some_url' => 'some_controller#some_action')
        subject
      end
    end
  end

  describe "#set_resource_context and #route_sets_for" do
    let(:resource_1) { double :resource_1, name: 'Resource_1' }
    let(:resource_2) { double :resource_2, name: 'Resource_2' }

    let(:resource_1_dynamic_proxy_router) { described_class.new }
    let(:resource_2_dynamic_proxy_router) { described_class.new }
    let(:alternate_resource_1_dynamic_proxy_router) { described_class.new }

    let(:expected_resource_1_route_sets) {
      resource_1_dynamic_proxy_router.set_resource_context(resource_1) do
        resource_1_dynamic_proxy_router.resources :some_resources, only: [:index, :show] do
          resource_1_dynamic_proxy_router.member do
            resource_1_dynamic_proxy_router.put :some_action
            resource_1_dynamic_proxy_router.post :some_action_2
          end
        end
      end

      resource_1_dynamic_proxy_router.route_sets_for(resource_1)
    }

    let(:unexpected_resource_1_route_sets) {
      alternate_resource_1_dynamic_proxy_router.set_resource_context(resource_1) do
        alternate_resource_1_dynamic_proxy_router.resources :some_resources, only: [:index, :show] do
          alternate_resource_1_dynamic_proxy_router.member do
            alternate_resource_1_dynamic_proxy_router.put :some_action
          end
          # not nested under member like the expected version is
          alternate_resource_1_dynamic_proxy_router.post :some_action_2
        end
      end

      alternate_resource_1_dynamic_proxy_router.route_sets_for(resource_1)
    }

    let(:expected_resource_2_route_sets) {
      resource_2_dynamic_proxy_router.set_resource_context(resource_2) do
        resource_2_dynamic_proxy_router.get '/some_url' => 'some_controller#some_action'
      end

      resource_2_dynamic_proxy_router.route_sets_for(resource_2)
    }

    before do
      dynamic_proxy_router.set_resource_context(resource_1) do
        dynamic_proxy_router.resources :some_resources, only: [:index, :show] do
          dynamic_proxy_router.member do
            dynamic_proxy_router.put :some_action
            dynamic_proxy_router.post :some_action_2
          end
        end
      end
      dynamic_proxy_router.set_resource_context(resource_2) do
        dynamic_proxy_router.get '/some_url' => 'some_controller#some_action'
      end
    end

    it "keeps track of resource context and returns correct route sets" do
      expect(dynamic_proxy_router.route_sets_for(resource_1)).to eq(expected_resource_1_route_sets)
      expect(dynamic_proxy_router.route_sets_for(resource_2)).to eq(expected_resource_2_route_sets)

      expect(dynamic_proxy_router.route_sets_for(resource_1))
        .not_to eq(unexpected_resource_1_route_sets)

      # sanity check
      expect(dynamic_proxy_router.leaf_count).to eq(3)
      expect(resource_1_dynamic_proxy_router.leaf_count).to eq(2)
      expect(resource_2_dynamic_proxy_router.leaf_count).to eq(1)
    end
  end
end
