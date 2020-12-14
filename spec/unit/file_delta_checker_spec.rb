require 'rails_helper'
require 'fileutils'

RSpec.describe ActiveAdmin::FileDeltaChecker do
  let(:application) { ActiveAdmin::Application.new }
  let(:test_dir) { File.expand_path("app/admin/public", application.app_path) }
  let(:test_file) { File.expand_path("app/admin/public/posts.rb", application.app_path) }

  let(:action) { double :action, call!: nil }
  let(:admin_dirs) {
    application.load_paths.each_with_object({}) { |path, admin_dirs|
      admin_dirs[path] = [:rb]
    }
  }
  let(:file_delta_checker) { described_class.new(admin_dirs) { action.call! } }

  describe "#execute_if_delta?" do
    it "should properly report whether a file was added or removed" do
      begin
        FileUtils.mkdir_p(test_dir)

        # no change - no trigger
        expect(file_delta_checker.delta?).to be false
        file_delta_checker.execute_if_delta
        expect(action).not_to have_received(:call!)

        # file added - trigger
        FileUtils.touch(test_file)
        expect(file_delta_checker.delta?).to be true
        file_delta_checker.execute_if_delta
        expect(action).to have_received(:call!).once

        # no change - no trigger
        expect(file_delta_checker.delta?).to be false
        file_delta_checker.execute_if_delta
        expect(action).to have_received(:call!).once # still once from file added

        # file touched - no trigger
        FileUtils.touch(test_file)
        expect(file_delta_checker.delta?).to be false
        file_delta_checker.execute_if_delta
        expect(action).to have_received(:call!).once # still once from file added

        # file deleted - trigger
        FileUtils.rm(test_file)
        expect(file_delta_checker.delta?).to be true
        file_delta_checker.execute_if_delta
        expect(action).to have_received(:call!).twice
      ensure
        FileUtils.remove_entry_secure(test_dir, force: true)
      end
    end
  end
end
