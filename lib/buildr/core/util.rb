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

require 'rbconfig'
require 'pathname'

module Buildr
  
  module Util
    extend self

    def java_platform?
      RUBY_PLATFORM =~ /java/
    end

    # In order to determine if we are running on a windows OS,
    # prefer this function instead of using Gem.win_platform?.
    #
    # Gem.win_platform? only checks the RUBY_PLATFORM global,
    # that in some cases like when running on JRuby is not 
    # succifient for our purpose:
    #
    # For JRuby, the value for RUBY_PLATFORM will always be 'java'
    # That's why this function checks on Config::CONFIG['host_os']
    def win_os?
      Config::CONFIG['host_os'] =~ /windows|cygwin|bccwin|cygwin|djgpp|mingw|mswin|wince/i
    end

    # Finds and returns path to executable.  Consults PATH environment variable.
    # Returns nil if executable not found.
    def which(name)
      if win_os?
        path = ENV['PATH'].split(File::PATH_SEPARATOR).map { |path| path.gsub('\\', '/') }.map { |path| "#{path}/#{name}.{exe,bat,com}" }
      else
        path = ENV['PATH'].split(File::PATH_SEPARATOR).map { |path| "#{path}/#{name}" }
      end
      FileList[path].existing.first
    end

    # Runs Ruby with these command line arguments.  The last argument may be a hash,
    # supporting the following keys:
    #   :command  -- Runs the specified script (e.g., :command=>'gem')
    #   :sudo     -- Run as sudo on operating systems that require it.
    #   :verbose  -- Override Rake's verbose flag.
    def ruby(*args)
      options = Hash === args.last ? args.pop : {}
      cmd = []
      ruby_bin = File.expand_path(Config::CONFIG['ruby_install_name'], Config::CONFIG['bindir'])
      if options.delete(:sudo) && !(win_os? || Process.uid == File.stat(ruby_bin).uid)
        cmd << 'sudo' << '-u' << '##{File.stat(ruby_bin).uid}'
      end
      cmd << ruby_bin
      cmd << '-S' << options.delete(:command) if options[:command]
      Rake.application.send :sh, *cmd.push(*args.flatten).push(options) do |ok, status|
        ok or fail "Command failed with status (#{status ? status.exitstatus : 'unknown'}): [#{cmd.join(" ")}]"
      end
    end

    # :call-seq:
    #  install_gems(*dependencies) 
    #
    def install_gems(*gems)
      installed = Gem::SourceIndex.from_installed_gems
      dependencies = gems.map do |gem| 
        case gem
        when Gem::Dependency then gem
        when Array then Gem::Dependency.new(*gem)
        when String then Gem::Dependency.new(gem, '> 0')
        else raise "Invalid gem dependency: #{gem.inspect}"
        end
      end
      dependencies.select { |dep| installed.search(dep.name, dep.version_requirements).empty? }.each do |dep|
        puts "Installing #{dep} ..."
        if win_os? # run the installer directly
          begin
            require 'rubygems/dependency_installer'
            Gem::DependencyInstaller.new(dep.name, dep.version_requirements).install
          rescue LoadError
            require 'rubygems/remote_installer'
            Gem::RemoteInstaller.new.install(dep.name, dep.version_requirements)
          end
        else
          ruby 'install', dep.name, '-v', dep.version_requirements.to_s.inspect, :command=>'gem', :sudo=>true
        end
      end
    end

    # Just like File.expand_path, but for windows systems it
    # capitalizes the drive name and ensures backslashes are used
    def normalize_path(path, *dirs)
      path = File.expand_path(path, *dirs)
      if win_os?
        path.gsub!('/', '\\').gsub!(/^[a-zA-Z]+:/) { |s| s.upcase }
      else
        path
      end
    end
    
    # Return the timestamp of file, without having to create a file task
    def timestamp(file)
      if File.exist?(file)
        File.mtime(file)
      else
        Rake::EARLY
      end
    end

    def relative_path(to, from = ".")
      to, from = File.expand_path(to, "/"), File.expand_path(from, "/")
      Pathname.new(to).relative_path_from(Pathname.new(from)).to_s
    end
  end
end

module Kernel #:nodoc:
  # Borrowed from Ruby 1.9.
  def tap
    yield self if block_given?
    self
  end unless method_defined?('tap')
end


class Symbol #:nodoc:
  # Borrowed from Ruby 1.9.
  def to_proc
    Proc.new{|*args| args.shift.__send__(self, *args)}
  end unless method_defined?('to_proc')
end


# Also borrowed from Ruby 1.9.
class BasicObject #:nodoc:
  (instance_methods - ['__send__', '__id__', '==', 'send', 'send!', 'respond_to?', 'equal?', 'object_id']).
    each do |method|
      undef_method method
    end

  def self.ancestors
    [Kernel]
  end
end


class OpenObject < Hash

  def initialize(source=nil, &block)
    @hash = Hash.new(&block)
    @hash.update(source) if source
  end

  def [](key)
    @hash[key]
  end

  def []=(key, value)
    @hash[key] = value
  end

  def delete(key)
    @hash.delete(key)
  end

  def to_hash
    @hash.clone
  end

  def method_missing(symbol, *args)
    if symbol.to_s =~ /=$/
      self[symbol.to_s[0..-2].to_sym] = args.first
    else
      self[symbol]
    end
  end
end

class Hash

  class << self

    # :call-seq:
    #   Hash.from_java_properties(string)
    #
    # Returns a hash from a string in the Java properties file format. For example:
    #   str = 'foo=bar\nbaz=fab'
    #   Hash.from_properties(str)
    #   => { 'foo'=>'bar', 'baz'=>'fab' }.to_properties
    def from_java_properties(string)
      string.gsub(/\\\n/, '').split("\n").select { |line| line =~ /^[^#].*=.*/ }.
        map { |line| line.gsub(/\\[trnf\\]/) { |escaped| {?t=>"\t", ?r=>"\r", ?n=>"\n", ?f=>"\f", ?\\=>"\\"}[escaped[1]] } }.
        map { |line| line.split('=') }.
        inject({}) { |hash, (name, value)| hash.merge(name=>value) }
    end

  end

  # :call-seq:
  #   only(keys*) => hash
  #
  # Returns a new hash with only the specified keys.
  #
  # For example:
  #   { :a=>1, :b=>2, :c=>3, :d=>4 }.only(:a, :c)
  #   => { :a=>1, :c=>3 }
  def only(*keys)
    keys.inject({}) { |hash, key| has_key?(key) ? hash.merge(key=>self[key]) : hash }
  end


  # :call-seq:
  #   except(keys*) => hash
  #
  # Returns a new hash without the specified keys.
  #
  # For example:
  #   { :a=>1, :b=>2, :c=>3, :d=>4 }.except(:a, :c)
  #   => { :b=>2, :d=>4 }
  def except(*keys)
    (self.keys - keys).inject({}) { |hash, key| hash.merge(key=>self[key]) }
  end

  # :call-seq:
  #   to_java_properties => string
  #
  # Convert hash to string format used for Java properties file. For example:
  #   { 'foo'=>'bar', 'baz'=>'fab' }.to_properties
  #   => foo=bar
  #      baz=fab
  def to_java_properties
    keys.sort.map { |key|
      value = self[key].gsub(/[\t\r\n\f\\]/) { |escape| "\\" + {"\t"=>"t", "\r"=>"r", "\n"=>"n", "\f"=>"f", "\\"=>"\\"}[escape] }
      "#{key}=#{value}"
    }.join("\n")
  end

end
