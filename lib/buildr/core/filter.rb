# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with this
# work for additional information regarding copyright ownership.  The ASF
# licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations under
# the License.


module Buildr

  # A filter knows how to copy files from one directory to another, applying mappings to the
  # contents of these files.
  #
  # You can specify the mapping using a Hash, and it will map ${key} fields found in each source
  # file into the appropriate value in the target file. For example:
  #
  #   filter.using 'version'=>'1.2', 'build'=>Time.now
  #
  # will replace all occurrences of <tt>${version}</tt> with <tt>1.2</tt>, and <tt>${build}</tt>
  # with the current date/time.
  #
  # You can also specify the mapping by passing a proc or a method, that will be called for
  # each source file, with the file name and content, returning the modified content.
  #
  # Without any mapping, the filter simply copies files from the source directory into the target
  # directory.
  #
  # A filter has one target directory, but you can specify any number of source directories,
  # either when creating the filter or calling #from. Include/exclude patterns are specified
  # relative to the source directories, so:
  #   filter.include '*.png'
  # will only include PNG files from any of the source directories.
  #
  # See Buildr#filter.
  class Filter

    def initialize #:nodoc:
      clear
    end

    # Returns the list of source directories (each being a file task).
    attr_reader :sources

    # :call-seq: 
    #   clear => self
    # 
    # Clear filter sources and include/exclude patterns
    def clear
      @include = []
      @exclude = []
      @sources = []
      self
    end

    # :call-seq:
    #   from(*sources) => self
    #
    # Adds additional directories from which to copy resources.
    #
    # For example:
    #   filter.from('src').into('target').using('build'=>Time.now)
    def from(*sources)
      @sources |= sources.flatten.map { |dir| file(File.expand_path(dir.to_s)) }
      self
    end

    # The target directory as a file task.
    attr_reader :target

    # :call-seq:
    #   into(dir) => self
    #
    # Sets the target directory into which files are copied and returns self.
    #
    # For example:
    #   filter.from('src').into('target').using('build'=>Time.now)
    def into(dir)
      @target = file(File.expand_path(dir.to_s)) { |task| run if target == task && !sources.empty? }
      self
    end

    # :call-seq:
    #   include(*files) => self
    #
    # Specifies files to include and returns self. See FileList#include.
    #
    # By default all files are included. You can use this method to only include specific
    # files form the source directory.
    def include(*files)
      @include += files
      self
    end
    alias :add :include 

    # :call-seq:
    #   exclude(*files) => self
    #
    # Specifies files to exclude and returns self. See FileList#exclude.
    def exclude(*files)
      @exclude += files
      self
    end

    # The mapping. See #using.
    attr_accessor :mapping

    # The mapper to use. See #using.
    attr_accessor :mapper

    # :call-seq:
    #   using(mapping) => self
    #   using { |file_name, contents| ... } => self
    #
    # Specifies the mapping to use and returns self.
    #
    # The most typical mapping uses a Hash, and the default mapping uses the Maven style, so
    # <code>${key}</code> are mapped to the values. You can change that by passing a different
    # format as the first argument. Currently supports:
    # * :ant -- Map <code>@key@</code>.
    # * :maven -- Map <code>${key}</code> (default).
    # * :ruby -- Map <code>#{key}</code>.
    # * Regexp -- Maps the matched data (e.g. <code>/=(.*?)=/</code>
    #
    # For example:
    #   filter.using 'version'=>'1.2'
    # Is the same as:
    #   filter.using :maven, 'version'=>'1.2'
    #
    # You can also pass a proc or method. It will be called with the file name and content,
    # to return the mapped content.
    #
    # Without any mapping, all files are copied as is.
    def using(*args, &block)
      case args.first
      when Hash # Maven hash mapping
        using :maven, *args
      when Symbol # Mapping from a method
        raise ArgumentError, 'Expected mapper type followed by mapping hash' unless args.size == 2 && Hash === args[1]
        @mapper, @mapping = *args
      when Regexp # Mapping using a regular expression
        raise ArgumentError, 'Expected regular expression followed by mapping hash' unless args.size == 2 && Hash === args[1]
        @mapper, @mapping = *args
      else
        raise ArgumentError, 'Expected proc, method or a block' if args.size > 1 || (args.first && block)
        @mapping = args.first || block
      end
      self
    end

    # :call-seq:
    #    run => boolean
    #
    # Runs the filter.
    def run
      raise 'No source directory specified, where am I going to find the files to filter?' if sources.empty?
      sources.each { |source| raise "Source directory #{source} doesn't exist" unless File.exist?(source.to_s) }
      raise 'No target directory specified, where am I going to copy the files to?' if target.nil?

      copy_map = sources.flatten.map(&:to_s).inject({}) do |map, source|
        base = Pathname.new(source)
        files = FileList.recursive(source).
          map { |file| Pathname.new(file).relative_path_from(base).to_s }.
          select { |file| @include.empty? || @include.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME) } }.
          reject { |file| @exclude.any? { |pattern| File.fnmatch(pattern, file, File::FNM_PATHNAME) } }
        files.each do |file|
          src, dest = File.expand_path(file, source), File.expand_path(file, target.to_s)
          map[file] = src if !File.exist?(dest) || File.stat(src).mtime > File.stat(dest).mtime
        end
        map
      end
        
      return false if copy_map.empty?

      verbose(Rake.application.options.trace || false) do
        mkpath target.to_s
        copy_map.each do |path, source|
          dest = File.expand_path(path, target.to_s)
          if File.directory?(source)
            mkpath dest
          else
            mkpath File.dirname(dest)
            case mapping
            when Proc, Method # Call on input, accept output.
              mapped = mapping.call(path, File.open(source, 'rb') { |file| file.read })
              File.open(dest, 'wb') { |file| file.write mapped }
            when Hash # Map ${key} to value
              content = File.open(source, 'rb') { |file| file.read }
              if Symbol === @mapper
                mapped = send("#{@mapper}_mapper", content) { |key| mapping[key] }
              else
                mapped = regexp_mapper(content) { |key| mapping[key] }
              end
                #gsub(/\$\{[^}]*\}/) { |str| mapping[str[2..-2]] || str }
              File.open(dest, 'wb') { |file| file.write mapped }
            when nil # No mapping.
              cp source, dest
              File.chmod(0664, dest)
            else
              fail "Filter can be a hash (key=>value), or a proc/method; I don't understand #{mapping}"
            end
          end
        end
        touch target.to_s 
      end
      true
    end

    # Returns the target directory. 
    def to_s
      @target.to_s
    end

  private

    def maven_mapper(content)
      content.gsub(/\$\{.*?\}/) { |str| yield(str[2..-2]) || str }
    end

    def ant_mapper(content)
      content.gsub(/@.*?@/) { |str| yield(str[1..-2]) || str }
    end

    def ruby_mapper(content)
      content.gsub(/#\{.*?\}/) { |str| yield(str[2..-2]) || str }
    end

    def regexp_mapper(content)
      content.gsub(@mapper) { |str| yield(str.scan(@mapper).join) || str }
    end

  end

  # :call-seq:
  #   filter(*source) => Filter
  #
  # Creates a filter that will copy files from the source directory(ies) into the target directory.
  # You can extend the filter to modify files by mapping <tt>${key}</tt> into values in each
  # of the copied files, and by including or excluding specific files.
  #
  # A filter is not a task, you must call the Filter#run method to execute it.
  #
  # For example, to copy all files from one directory to another:
  #   filter('src/files').into('target/classes').run
  # To include only the text files, and replace each instance of <tt>${build}</tt> with the current
  # date/time:
  #   filter('src/files').into('target/classes').include('*.txt').using('build'=>Time.now).run
  def filter(*sources)
    Filter.new.from(*sources)
  end

end