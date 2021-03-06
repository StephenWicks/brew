module MachO
  # Represents a Mach-O file, which contains a header and load commands
  # as well as binary executable instructions. Mach-O binaries are
  # architecture specific.
  # @see https://en.wikipedia.org/wiki/Mach-O
  # @see MachO::FatFile
  class MachOFile
    # @return [String] the filename loaded from, or nil if loaded from a binary string
    attr_accessor :filename

    # @return [Symbol] the endianness of the file, :big or :little
    attr_reader :endianness

    # @return [MachO::MachHeader] if the Mach-O is 32-bit
    # @return [MachO::MachHeader64] if the Mach-O is 64-bit
    attr_reader :header

    # @return [Array<MachO::LoadCommand>] an array of the file's load commands
    # @note load commands are provided in order of ascending offset.
    attr_reader :load_commands

    # Creates a new MachOFile instance from a binary string.
    # @param bin [String] a binary string containing raw Mach-O data
    # @return [MachO::MachOFile] a new MachOFile
    def self.new_from_bin(bin)
      instance = allocate
      instance.initialize_from_bin(bin)

      instance
    end

    # Creates a new FatFile from the given filename.
    # @param filename [String] the Mach-O file to load from
    # @raise [ArgumentError] if the given file does not exist
    def initialize(filename)
      raise ArgumentError, "#{filename}: no such file" unless File.file?(filename)

      @filename = filename
      @raw_data = File.open(@filename, "rb", &:read)
      populate_fields
    end

    # Initializes a new MachOFile instance from a binary string.
    # @see MachO::MachOFile.new_from_bin
    # @api private
    def initialize_from_bin(bin)
      @filename = nil
      @raw_data = bin
      populate_fields
    end

    # The file's raw Mach-O data.
    # @return [String] the raw Mach-O data
    def serialize
      @raw_data
    end

    # @return [Boolean] true if the Mach-O has 32-bit magic, false otherwise
    def magic32?
      Utils.magic32?(header.magic)
    end

    # @return [Boolean] true if the Mach-O has 64-bit magic, false otherwise
    def magic64?
      Utils.magic64?(header.magic)
    end

    # @return [Fixnum] the file's internal alignment
    def alignment
      magic32? ? 4 : 8
    end

    # @return [Boolean] true if the file is of type `MH_OBJECT`, false otherwise
    def object?
      header.filetype == MH_OBJECT
    end

    # @return [Boolean] true if the file is of type `MH_EXECUTE`, false otherwise
    def executable?
      header.filetype == MH_EXECUTE
    end

    # @return [Boolean] true if the file is of type `MH_FVMLIB`, false otherwise
    def fvmlib?
      header.filetype == MH_FVMLIB
    end

    # @return [Boolean] true if the file is of type `MH_CORE`, false otherwise
    def core?
      header.filetype == MH_CORE
    end

    # @return [Boolean] true if the file is of type `MH_PRELOAD`, false otherwise
    def preload?
      header.filetype == MH_PRELOAD
    end

    # @return [Boolean] true if the file is of type `MH_DYLIB`, false otherwise
    def dylib?
      header.filetype == MH_DYLIB
    end

    # @return [Boolean] true if the file is of type `MH_DYLINKER`, false otherwise
    def dylinker?
      header.filetype == MH_DYLINKER
    end

    # @return [Boolean] true if the file is of type `MH_BUNDLE`, false otherwise
    def bundle?
      header.filetype == MH_BUNDLE
    end

    # @return [Boolean] true if the file is of type `MH_DSYM`, false otherwise
    def dsym?
      header.filetype == MH_DSYM
    end

    # @return [Boolean] true if the file is of type `MH_KEXT_BUNDLE`, false otherwise
    def kext?
      header.filetype == MH_KEXT_BUNDLE
    end

    # @return [Fixnum] the file's magic number
    def magic
      header.magic
    end

    # @return [String] a string representation of the file's magic number
    def magic_string
      MH_MAGICS[magic]
    end

    # @return [Symbol] a string representation of the Mach-O's filetype
    def filetype
      MH_FILETYPES[header.filetype]
    end

    # @return [Symbol] a symbol representation of the Mach-O's CPU type
    def cputype
      CPU_TYPES[header.cputype]
    end

    # @return [Symbol] a symbol representation of the Mach-O's CPU subtype
    def cpusubtype
      CPU_SUBTYPES[header.cputype][header.cpusubtype]
    end

    # @return [Fixnum] the number of load commands in the Mach-O's header
    def ncmds
      header.ncmds
    end

    # @return [Fixnum] the size of all load commands, in bytes
    def sizeofcmds
      header.sizeofcmds
    end

    # @return [Fixnum] execution flags set by the linker
    def flags
      header.flags
    end

    # All load commands of a given name.
    # @example
    #  file.command("LC_LOAD_DYLIB")
    #  file[:LC_LOAD_DYLIB]
    # @param [String, Symbol] name the load command ID
    # @return [Array<MachO::LoadCommand>] an array of LoadCommands corresponding to `name`
    def command(name)
      load_commands.select { |lc| lc.type == name.to_sym }
    end

    alias [] command

    # Inserts a load command at the given offset.
    # @param offset [Fixnum] the offset to insert at
    # @param lc [MachO::LoadCommand] the load command to insert
    # @param options [Hash]
    # @option options [Boolean] :repopulate (true) whether or not to repopulate
    #  the instance fields
    # @raise [MachO::OffsetInsertionError] if the offset is not in the load command region
    # @raise [MachO::HeaderPadError] if the new command exceeds the header pad buffer
    # @note Calling this method with an arbitrary offset in the load command
    #  region **will leave the object in an inconsistent state**.
    def insert_command(offset, lc, options = {})
      context = LoadCommand::SerializationContext.context_for(self)
      cmd_raw = lc.serialize(context)

      if offset < header.class.bytesize || offset + cmd_raw.bytesize > low_fileoff
        raise OffsetInsertionError, offset
      end

      new_sizeofcmds = sizeofcmds + cmd_raw.bytesize

      if header.class.bytesize + new_sizeofcmds > low_fileoff
        raise HeaderPadError, @filename
      end

      # update Mach-O header fields to account for inserted load command
      update_ncmds(ncmds + 1)
      update_sizeofcmds(new_sizeofcmds)

      @raw_data.insert(offset, cmd_raw)
      @raw_data.slice!(header.class.bytesize + new_sizeofcmds, cmd_raw.bytesize)

      populate_fields if options.fetch(:repopulate, true)
    end

    # Replace a load command with another command in the Mach-O, preserving location.
    # @param old_lc [MachO::LoadCommand] the load command being replaced
    # @param new_lc [MachO::LoadCommand] the load command being added
    # @return [void]
    # @raise [MachO::HeaderPadError] if the new command exceeds the header pad buffer
    # @see {#insert_command}
    # @note This is public, but methods like {#dylib_id=} should be preferred.
    def replace_command(old_lc, new_lc)
      context = LoadCommand::SerializationContext.context_for(self)
      cmd_raw = new_lc.serialize(context)
      new_sizeofcmds = sizeofcmds + cmd_raw.bytesize - old_lc.cmdsize
      if header.class.bytesize + new_sizeofcmds > low_fileoff
        raise HeaderPadError, @filename
      end

      delete_command(old_lc)
      insert_command(old_lc.view.offset, new_lc)
    end

    # Appends a new load command to the Mach-O.
    # @param lc [MachO::LoadCommand] the load command being added
    # @param options [Hash]
    # @option options [Boolean] :repopulate (true) whether or not to repopulate
    #  the instance fields
    # @return [void]
    # @see {#insert_command}
    # @note This is public, but methods like {#add_rpath} should be preferred.
    #  Setting `repopulate` to false **will leave the instance in an
    #  inconsistent state** unless {#populate_fields} is called **immediately**
    #  afterwards.
    def add_command(lc, options = {})
      insert_command(header.class.bytesize + sizeofcmds, lc, options)
    end

    # Delete a load command from the Mach-O.
    # @param lc [MachO::LoadCommand] the load command being deleted
    # @param options [Hash]
    # @option options [Boolean] :repopulate (true) whether or not to repopulate
    #  the instance fields
    # @return [void]
    # @note This is public, but methods like {#delete_rpath} should be preferred.
    #  Setting `repopulate` to false **will leave the instance in an
    #  inconsistent state** unless {#populate_fields} is called **immediately**
    #  afterwards.
    def delete_command(lc, options = {})
      @raw_data.slice!(lc.view.offset, lc.cmdsize)

      # update Mach-O header fields to account for deleted load command
      update_ncmds(ncmds - 1)
      update_sizeofcmds(sizeofcmds - lc.cmdsize)

      # pad the space after the load commands to preserve offsets
      null_pad = "\x00" * lc.cmdsize
      @raw_data.insert(header.class.bytesize + sizeofcmds - lc.cmdsize, null_pad)

      populate_fields if options.fetch(:repopulate, true)
    end

    # Populate the instance's fields with the raw Mach-O data.
    # @return [void]
    # @note This method is public, but should (almost) never need to be called.
    #  The exception to this rule is when methods like {#add_command} and
    #  {#delete_command} have been called with `repopulate = false`.
    def populate_fields
      @header = populate_mach_header
      @load_commands = populate_load_commands
    end

    # All load commands responsible for loading dylibs.
    # @return [Array<MachO::DylibCommand>] an array of DylibCommands
    def dylib_load_commands
      load_commands.select { |lc| DYLIB_LOAD_COMMANDS.include?(lc.type) }
    end

    # All segment load commands in the Mach-O.
    # @return [Array<MachO::SegmentCommand>] if the Mach-O is 32-bit
    # @return [Array<MachO::SegmentCommand64>] if the Mach-O is 64-bit
    def segments
      if magic32?
        command(:LC_SEGMENT)
      else
        command(:LC_SEGMENT_64)
      end
    end

    # The Mach-O's dylib ID, or `nil` if not a dylib.
    # @example
    #  file.dylib_id # => 'libBar.dylib'
    # @return [String, nil] the Mach-O's dylib ID
    def dylib_id
      return unless dylib?

      dylib_id_cmd = command(:LC_ID_DYLIB).first

      dylib_id_cmd.name.to_s
    end

    # Changes the Mach-O's dylib ID to `new_id`. Does nothing if not a dylib.
    # @example
    #  file.change_dylib_id("libFoo.dylib")
    # @param new_id [String] the dylib's new ID
    # @param _options [Hash]
    # @return [void]
    # @raise [ArgumentError] if `new_id` is not a String
    # @note `_options` is currently unused and is provided for signature
    #  compatibility with {MachO::FatFile#change_dylib_id}
    def change_dylib_id(new_id, _options = {})
      raise ArgumentError, "new ID must be a String" unless new_id.is_a?(String)
      return unless dylib?

      old_lc = command(:LC_ID_DYLIB).first
      raise DylibIdMissingError unless old_lc

      new_lc = LoadCommand.create(:LC_ID_DYLIB, new_id,
                                  old_lc.timestamp,
                                  old_lc.current_version,
                                  old_lc.compatibility_version)

      replace_command(old_lc, new_lc)
    end

    alias dylib_id= change_dylib_id

    # All shared libraries linked to the Mach-O.
    # @return [Array<String>] an array of all shared libraries
    def linked_dylibs
      # Some linkers produce multiple `LC_LOAD_DYLIB` load commands for the same
      # library, but at this point we're really only interested in a list of
      # unique libraries this Mach-O file links to, thus: `uniq`. (This is also
      # for consistency with `FatFile` that merges this list across all archs.)
      dylib_load_commands.map(&:name).map(&:to_s).uniq
    end

    # Changes the shared library `old_name` to `new_name`
    # @example
    #  file.change_install_name("/usr/lib/libWhatever.dylib", "/usr/local/lib/libWhatever2.dylib")
    # @param old_name [String] the shared library's old name
    # @param new_name [String] the shared library's new name
    # @param _options [Hash]
    # @return [void]
    # @raise [MachO::DylibUnknownError] if no shared library has the old name
    # @note `_options` is currently unused and is provided for signature
    #  compatibility with {MachO::FatFile#change_install_name}
    def change_install_name(old_name, new_name, _options = {})
      old_lc = dylib_load_commands.find { |d| d.name.to_s == old_name }
      raise DylibUnknownError, old_name if old_lc.nil?

      new_lc = LoadCommand.create(old_lc.type, new_name,
                                  old_lc.timestamp,
                                  old_lc.current_version,
                                  old_lc.compatibility_version)

      replace_command(old_lc, new_lc)
    end

    alias change_dylib change_install_name

    # All runtime paths searched by the dynamic linker for the Mach-O.
    # @return [Array<String>] an array of all runtime paths
    def rpaths
      command(:LC_RPATH).map(&:path).map(&:to_s)
    end

    # Changes the runtime path `old_path` to `new_path`
    # @example
    #  file.change_rpath("/usr/lib", "/usr/local/lib")
    # @param old_path [String] the old runtime path
    # @param new_path [String] the new runtime path
    # @param _options [Hash]
    # @return [void]
    # @raise [MachO::RpathUnknownError] if no such old runtime path exists
    # @raise [MachO::RpathExistsError] if the new runtime path already exists
    # @note `_options` is currently unused and is provided for signature
    #  compatibility with {MachO::FatFile#change_rpath}
    def change_rpath(old_path, new_path, _options = {})
      old_lc = command(:LC_RPATH).find { |r| r.path.to_s == old_path }
      raise RpathUnknownError, old_path if old_lc.nil?
      raise RpathExistsError, new_path if rpaths.include?(new_path)

      new_lc = LoadCommand.create(:LC_RPATH, new_path)

      delete_rpath(old_path)
      insert_command(old_lc.view.offset, new_lc)
    end

    # Add the given runtime path to the Mach-O.
    # @example
    #  file.rpaths # => ["/lib"]
    #  file.add_rpath("/usr/lib")
    #  file.rpaths # => ["/lib", "/usr/lib"]
    # @param path [String] the new runtime path
    # @param _options [Hash]
    # @return [void]
    # @raise [MachO::RpathExistsError] if the runtime path already exists
    # @note `_options` is currently unused and is provided for signature
    #  compatibility with {MachO::FatFile#add_rpath}
    def add_rpath(path, _options = {})
      raise RpathExistsError, path if rpaths.include?(path)

      rpath_cmd = LoadCommand.create(:LC_RPATH, path)
      add_command(rpath_cmd)
    end

    # Delete the given runtime path from the Mach-O.
    # @example
    #  file.rpaths # => ["/lib"]
    #  file.delete_rpath("/lib")
    #  file.rpaths # => []
    # @param path [String] the runtime path to delete
    # @param _options [Hash]
    # @return void
    # @raise [MachO::RpathUnknownError] if no such runtime path exists
    # @note `_options` is currently unused and is provided for signature
    #  compatibility with {MachO::FatFile#delete_rpath}
    def delete_rpath(path, _options = {})
      rpath_cmds = command(:LC_RPATH).select { |r| r.path.to_s == path }
      raise RpathUnknownError, path if rpath_cmds.empty?

      # delete the commands in reverse order, offset descending. this
      # allows us to defer (expensive) field population until the very end
      rpath_cmds.reverse_each { |cmd| delete_command(cmd, :repopulate => false) }

      populate_fields
    end

    # All sections of the segment `segment`.
    # @param segment [MachO::SegmentCommand, MachO::SegmentCommand64] the segment being inspected
    # @return [Array<MachO::Section>] if the Mach-O is 32-bit
    # @return [Array<MachO::Section64>] if the Mach-O is 64-bit
    # @deprecated use {MachO::SegmentCommand#sections} instead
    def sections(segment)
      segment.sections
    end

    # Write all Mach-O data to the given filename.
    # @param filename [String] the file to write to
    # @return [void]
    def write(filename)
      File.open(filename, "wb") { |f| f.write(@raw_data) }
    end

    # Write all Mach-O data to the file used to initialize the instance.
    # @return [void]
    # @raise [MachO::MachOError] if the instance was initialized without a file
    # @note Overwrites all data in the file!
    def write!
      if @filename.nil?
        raise MachOError, "cannot write to a default file when initialized from a binary string"
      else
        File.open(@filename, "wb") { |f| f.write(@raw_data) }
      end
    end

    private

    # The file's Mach-O header structure.
    # @return [MachO::MachHeader] if the Mach-O is 32-bit
    # @return [MachO::MachHeader64] if the Mach-O is 64-bit
    # @raise [MachO::TruncatedFileError] if the file is too small to have a valid header
    # @api private
    def populate_mach_header
      # the smallest Mach-O header is 28 bytes
      raise TruncatedFileError if @raw_data.size < 28

      magic = populate_and_check_magic
      mh_klass = Utils.magic32?(magic) ? MachHeader : MachHeader64
      mh = mh_klass.new_from_bin(endianness, @raw_data[0, mh_klass.bytesize])

      check_cputype(mh.cputype)
      check_cpusubtype(mh.cputype, mh.cpusubtype)
      check_filetype(mh.filetype)

      mh
    end

    # Read just the file's magic number and check its validity.
    # @return [Fixnum] the magic
    # @raise [MachO::MagicError] if the magic is not valid Mach-O magic
    # @raise [MachO::FatBinaryError] if the magic is for a Fat file
    # @api private
    def populate_and_check_magic
      magic = @raw_data[0..3].unpack("N").first

      raise MagicError, magic unless Utils.magic?(magic)
      raise FatBinaryError if Utils.fat_magic?(magic)

      @endianness = Utils.little_magic?(magic) ? :little : :big

      magic
    end

    # Check the file's CPU type.
    # @param cputype [Fixnum] the CPU type
    # @raise [MachO::CPUTypeError] if the CPU type is unknown
    # @api private
    def check_cputype(cputype)
      raise CPUTypeError, cputype unless CPU_TYPES.key?(cputype)
    end

    # Check the file's CPU type/subtype pair.
    # @param cpusubtype [Fixnum] the CPU subtype
    # @raise [MachO::CPUSubtypeError] if the CPU sub-type is unknown
    # @api private
    def check_cpusubtype(cputype, cpusubtype)
      # Only check sub-type w/o capability bits (see `populate_mach_header`).
      raise CPUSubtypeError.new(cputype, cpusubtype) unless CPU_SUBTYPES[cputype].key?(cpusubtype)
    end

    # Check the file's type.
    # @param filetype [Fixnum] the file type
    # @raise [MachO::FiletypeError] if the file type is unknown
    # @api private
    def check_filetype(filetype)
      raise FiletypeError, filetype unless MH_FILETYPES.key?(filetype)
    end

    # All load commands in the file.
    # @return [Array<MachO::LoadCommand>] an array of load commands
    # @raise [MachO::LoadCommandError] if an unknown load command is encountered
    # @api private
    def populate_load_commands
      offset = header.class.bytesize
      load_commands = []

      header.ncmds.times do
        fmt = Utils.specialize_format("L=", endianness)
        cmd = @raw_data.slice(offset, 4).unpack(fmt).first
        cmd_sym = LOAD_COMMANDS[cmd]

        raise LoadCommandError, cmd if cmd_sym.nil?

        # why do I do this? i don't like declaring constants below
        # classes, and i need them to resolve...
        klass = MachO.const_get LC_STRUCTURES[cmd_sym]
        view = MachOView.new(@raw_data, endianness, offset)
        command = klass.new_from_bin(view)

        load_commands << command
        offset += command.cmdsize
      end

      load_commands
    end

    # The low file offset (offset to first section data).
    # @return [Fixnum] the offset
    # @api private
    def low_fileoff
      offset = @raw_data.size

      segments.each do |seg|
        seg.sections.each do |sect|
          next if sect.empty?
          next if sect.flag?(:S_ZEROFILL)
          next if sect.flag?(:S_THREAD_LOCAL_ZEROFILL)
          next unless sect.offset < offset

          offset = sect.offset
        end
      end

      offset
    end

    # Updates the number of load commands in the raw data.
    # @param ncmds [Fixnum] the new number of commands
    # @return [void]
    # @api private
    def update_ncmds(ncmds)
      fmt = Utils.specialize_format("L=", endianness)
      ncmds_raw = [ncmds].pack(fmt)
      @raw_data[16..19] = ncmds_raw
    end

    # Updates the size of all load commands in the raw data.
    # @param size [Fixnum] the new size, in bytes
    # @return [void]
    # @api private
    def update_sizeofcmds(size)
      fmt = Utils.specialize_format("L=", endianness)
      size_raw = [size].pack(fmt)
      @raw_data[20..23] = size_raw
    end
  end
end
