#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fluent/plugin/input'

module Fluent::Plugin
  class TailInput < Fluent::Plugin::Input
    class PositionFile
      UNWATCHED_POSITION = 0xffffffffffffffff
      # The device column is optional because position files written by older
      # versions of Fluentd do not have it.
      POSITION_FILE_ENTRY_REGEX = /^([^\t]+)\t([0-9a-fA-F]+)\t([0-9a-fA-F]+)(?:\t([0-9a-fA-F]+))?/.freeze

      def self.load(file, follow_inodes, existing_targets, logger:)
        pf = new(file, follow_inodes, logger: logger)
        pf.load(existing_targets)
        pf
      end

      def initialize(file, follow_inodes, logger: nil)
        @file = file
        @logger = logger
        @file_mutex = Mutex.new
        @map = {}
        @follow_inodes = follow_inodes
      end

      def [](target_info)
        key = target_info.position_key(@follow_inodes)
        if m = @map[key]
          return m
        end

        @file_mutex.synchronize {
          @file.seek(0, IO::SEEK_END)
          seek = @file.pos + target_info.path.bytesize + 1
          dev = @follow_inodes ? target_info.dev : nil
          @file.write Entry.new(target_info.path, 0, 0, seek, dev).to_entry_fmt
          @map[key] = FilePositionEntry.new(@file, @file_mutex, seek, 0, 0)
        }
      end

      def unwatch_removed_targets(existing_targets)
        @map.reject { |key, entry|
          existing_targets.key?(key)
        }.each_key { |key|
          unwatch_key(key)
        }
      end

      def unwatch(target_info)
        unwatch_key(target_info.position_key(@follow_inodes))
      end

      def load(existing_targets = nil)
        compact(existing_targets)

        map = {}
        @file_mutex.synchronize do
          @file.pos = 0

          @file.each_line do |line|
            m = POSITION_FILE_ENTRY_REGEX.match(line)
            next if m.nil?

            path = m[1]
            pos = m[2].to_i(16)
            ino = m[3].to_i(16)
            dev = m[4]&.to_i(16)
            seek = @file.pos - line.bytesize + path.bytesize + 1
            if @follow_inodes
              # The device of an entry of a position file written by an older
              # version is nil because it has no device column.
              map[[ino, dev]] = FilePositionEntry.new(@file, @file_mutex, seek, pos, ino)
            else
              map[path] = FilePositionEntry.new(@file, @file_mutex, seek, pos, ino)
            end
          end
        end

        @map = map
      end

      # This method is similar to #compact but it tries to get less lock to avoid a lock contention
      def try_compact
        last_modified = nil
        size = nil

        @file_mutex.synchronize do
          size = @file.size
          last_modified = @file.mtime
        end

        entries = fetch_compacted_entries
        @logger&.debug "Compacted entries: ", entries.keys

        @file_mutex.synchronize do
          if last_modified == @file.mtime && size == @file.size
            @file.pos = 0
            @file.truncate(0)
            @file.write(entries.values.map(&:to_entry_fmt).join)

            # entry contains path/ino key and value.
            entries.each do |key, val|
              if (m = @map[key])
                m.seek = val.seek
              end
            end
          else
            # skip
          end
        end
      end

      private

      def unwatch_key(key)
        if (entry = @map.delete(key))
          entry.update_pos(UNWATCHED_POSITION)
        end
      end

      def compact(existing_targets = nil)
        @file_mutex.synchronize do
          entries = fetch_compacted_entries
          @logger&.debug "Compacted entries: ", entries.keys

          if existing_targets
            entries = remove_deleted_files_entries(entries, existing_targets)
            @logger&.debug "Remove missing entries.",
                           existing_targets: existing_targets.keys,
                           entries_after_removing: entries.keys
          end

          @file.pos = 0
          @file.truncate(0)
          @file.write(entries.values.map(&:to_entry_fmt).join)
        end
      end

      def fetch_compacted_entries
        entries = {}

        @file.pos = 0
        file_pos = 0
        @file.each_line do |line|
          m = POSITION_FILE_ENTRY_REGEX.match(line)
          if m.nil?
            @logger.warn "Unparsable line in pos_file: #{line}" if @logger
            next
          end

          path = m[1]
          pos = m[2].to_i(16)
          ino = m[3].to_i(16)
          dev = m[4]&.to_i(16) if @follow_inodes
          if pos == UNWATCHED_POSITION
            @logger.debug "Remove unwatched line from pos_file: #{line}" if @logger
          else
            if @follow_inodes
              # Inode numbers are unique only within a device, so entries of
              # files on different devices can share one. See #4326.
              key = [ino, dev]
              @logger&.warn("#{path} (inode: #{ino}, device: #{dev}) already exists. use latest one: deleted #{entries[key]}") if entries.include?(key)
              entries[key] = Entry.new(path, pos, ino, file_pos + path.bytesize + 1, dev)
            else
              @logger&.warn("#{path} already exists. use latest one: deleted #{entries[path]}") if entries.include?(path)
              entries[path] = Entry.new(path, pos, ino, file_pos + path.bytesize + 1)
            end
            file_pos += line.size
          end
        end

        entries
      end

      def remove_deleted_files_entries(existent_entries, existing_targets)
        unless @follow_inodes
          return existent_entries.select { |path, _| existing_targets.key?(path) }
        end

        # A position file written by an older version has no device column.
        # Resolve the device of such an entry by the recorded path, or by an
        # inode which is not shared by files on different devices, so that the
        # position is kept after upgrading Fluentd.
        targets_by_path = {}
        targets_by_ino = Hash.new { |hash, ino| hash[ino] = [] }
        existing_targets.each_value do |target|
          targets_by_path[target.path] = target
          targets_by_ino[target.ino] << target
        end

        entries = {}
        existent_entries.each do |(ino, dev), entry|
          if dev.nil?
            # Resolve the device by the recorded path, or by an inode which is
            # not shared by files on different devices.
            target = targets_by_path[entry.path]
            target = nil if target && target.ino != ino
            if target.nil?
              targets = targets_by_ino[ino]
              target = targets.first if targets.size == 1
            end
            next if target.nil?
            entry.dev = dev = target.dev
          end
          key = [ino, dev]
          entries[key] = entry if existing_targets.key?(key)
        end
        entries
      end
    end

    Entry = Struct.new(:path, :pos, :ino, :seek, :dev) do
      POSITION_FILE_ENTRY_FORMAT = "%s\t%016x\t%016x\n".freeze
      POSITION_FILE_ENTRY_WITH_DEVICE_FORMAT = "%s\t%016x\t%016x\t%016x\n".freeze

      def to_entry_fmt
        if dev
          POSITION_FILE_ENTRY_WITH_DEVICE_FORMAT % [path, pos, ino, dev]
        else
          POSITION_FILE_ENTRY_FORMAT % [path, pos, ino]
        end
      end
    end

    # pos               inode
    # ffffffffffffffff\tffffffffffffffff\n
    class FilePositionEntry
      POS_SIZE = 16
      INO_OFFSET = 17
      INO_SIZE = 16
      LN_OFFSET = 33
      SIZE = 34

      def initialize(file, file_mutex, seek, pos, inode)
        @file = file
        @file_mutex = file_mutex
        @seek = seek
        @pos = pos
        @inode = inode
      end

      attr_writer :seek

      def update(ino, pos)
        @file_mutex.synchronize {
          @file.pos = @seek
          @file.write "%016x\t%016x" % [pos, ino]
        }
        @pos = pos
        @inode = ino
      end

      def update_pos(pos)
        @file_mutex.synchronize {
          @file.pos = @seek
          @file.write "%016x" % pos
        }
        @pos = pos
      end

      def read_inode
        @inode
      end

      def read_pos
        @pos
      end
    end

    class MemoryPositionEntry
      def initialize
        @pos = 0
        @inode = 0
      end

      def update(ino, pos)
        @inode = ino
        @pos = pos
      end

      def update_pos(pos)
        @pos = pos
      end

      def read_pos
        @pos
      end

      def read_inode
        @inode
      end
    end

    TargetInfo = Struct.new(:path, :ino, :dev) do
      # The key of the position entry of this target. When following inodes,
      # the pair of inode and device identifies a file because inode numbers
      # are unique only within one device. See #4326.
      def position_key(follow_inodes)
        follow_inodes ? [ino, dev] : path
      end
    end
  end
end
