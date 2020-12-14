module ActiveAdmin
  # FileDeltaChecker specifies an API to determine whether a file as
  # added or removed to control reloading.  The API depends on four methods:
  #
  # Modeled after ActiveSupport::FileUpdateChecker
  #
  # * +initialize+ which expects two parameters and one block as
  #   described below.
  #
  # * +delta?+ which returns a boolean if a file was added or removed.
  #
  # * +execute+ which executes the given block on initialization
  #   and updates the latest watched directories.
  #
  # * +execute_if_delta+ which just executes the block if there was a delta.
  #
  # After initialization, a call to +execute_if_delta+ must execute
  # the block only if there was really a change in the filesystem.
  #
  class FileDeltaChecker
    # It accepts one parameter on initialization, which is hash of directories.
    # The hash must have directories as keys and the value is an array of extensions
    # to be watched under that directory.
    #
    # This method must also receive a block that will be called once there is
    # a delta.  The array of files and list of directories cannot be changed
    # after FileDeltaChecker has been initialized.
    def initialize(dirs, &block)
      @glob  = compile_glob(dirs)
      @block = block

      @watched    = nil
      @last_watched   = watched
    end

    # Check if any files were added or removed. If so, the watched
    # value is cached until the block is executed via +execute+ or +execute_if_delta+.
    def delta?
      current_watched = watched
      if @last_watched != watched
        @watched = current_watched
        true
      else
        false
      end
    end

    # Executes the given block and updates the latest watched files.
    def execute
      @last_watched = watched
      @block.call
    ensure
      @watched = nil
    end

    # Execute the block given if there was a delta.
    def execute_if_delta
      if delta?
        yield if block_given?
        execute
        true
      else
        false
      end
    end

    private

    def watched
      @watched || Dir[@glob]
    end

    def compile_glob(hash)
      hash.freeze # Freeze so changes aren't accidentally pushed
      return if hash.empty?

      globs = hash.map do |key, value|
        "#{escape(key)}/**/*#{compile_ext(value)}"
      end
      "{#{globs.join(",")}}"
    end

    def escape(key)
      key.gsub(',','\,')
    end

    def compile_ext(array)
      array = Array(array)
      return if array.empty?
      ".{#{array.join(",")}}"
    end
  end
end
