# frozen_string_literal: true
if ENV["COVERAGE"] == "true"
  require "simplecov"

  SimpleCov.command_name "filesystem changes specs"
end
