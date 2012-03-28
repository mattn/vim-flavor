require 'bundler/setup'
require 'fileutils'
require 'thor'
require 'vim-flavor/version'
require 'yaml'

module Vim
  module Flavor
    module StringExtension
      def to_flavors_path()
        "#{self}/flavors"
      end
    end

    class ::String
      include StringExtension
    end

    class VersionConstraint
      attr_reader :base_version, :operator

      def initialize(s)
        @base_version, @operator = parse(s)
      end

      def to_s()
        "#{@operator} #{@base_version}"
      end

      def ==(other)
        self.base_version == other.base_version &&
          self.operator == other.operator
      end

      def parse(s)
        m = /^\s*(>=|~>)\s+(\S+)$/.match(s)
        if m then
          [Gem::Version.create(m[2]), m[1]]
        else
          raise "Invalid version constraint: #{s.inspect}"
        end
      end

      def compatible?(other_version_or_s)
        v = Gem::Version.create(other_version_or_s)
        if @operator == '~>' then
          self.base_version.bump() > v and v >= self.base_version
        elsif @operator == '>=' then
          v >= self.base_version
        else
          raise NotImplementedError
        end
      end

      def find_the_best_version(versions)
        versions.
          select {|v| compatible?(v)}.
          sort().
          reverse().
          first
      end
    end

    class << self
      @@dot_path = File.expand_path('~/.vim-flavor')

      def dot_path
        @@dot_path
      end

      def dot_path= path
        @@dot_path = path
      end
    end

    class Flavor
      @@properties = [
        :groups,
        :locked_version,
        :repo_name,
        :repo_uri,
        :version_contraint,
      ]

      @@properties.each do |p|
        attr_accessor p
      end

      def initialize()
        @groups = []
      end

      def ==(other)
        return false if self.class != other.class
        @@properties.all? do |p|
          self.send(p) == other.send(p)
        end
      end

      def zapped_repo_dir_name
        @repo_name.gsub(/[^A-Za-z0-9._-]/, '_')
      end

      def cached_repo_path
        @cached_repo_path ||=
          "#{Vim::Flavor.dot_path}/repos/#{zapped_repo_dir_name}"
      end

      def make_deploy_path(vimfiles_path)
        "#{vimfiles_path.to_flavors_path()}/#{zapped_repo_dir_name}"
      end

      def clone()
        if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/
          message = %x[
            git clone #{@repo_uri} #{cached_repo_path} 2>&1
          ]
        else
          message = %x[
            {
              git clone '#{@repo_uri}' '#{cached_repo_path}'
            } 2>&1
          ]
        end
        if $? != 0 then
          raise RuntimeError, message
        end
        true
      end

      def fetch()
        if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/
          message = %x[
            cd #{cached_repo_path.inspect.tr('/', '\\')} &
            git fetch origin 2>&1
          ]
        else
          message = %x[
            {
              cd #{cached_repo_path.inspect} &&
              git fetch origin
            } 2>&1
          ]
        end
        if $? != 0 then
          raise RuntimeError, message
        end
      end

      def deploy(vimfiles_path)
        deploy_path = make_deploy_path(vimfiles_path)
        if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/
          message = %x[
            cd "#{cached_repo_path.tr('/', '\\')}" &
            git checkout -f #{locked_version.inspect} &
            git checkout-index -a -f --prefix="#{deploy_path}/" &
            vim -u NONE -i NONE -n -N -e -s -c " &
              silent! helptags #{deploy_path}/doc
              qall!
            "
            2>&1
          ]
        else
          message = %x[
            {
              cd '#{cached_repo_path}' &&
              git checkout -f #{locked_version.inspect} &&
              git checkout-index -a -f --prefix='#{deploy_path}/' &&
              {
                vim -u NONE -i NONE -n -N -e -s -c '
                  silent! helptags #{deploy_path}/doc
                  qall!
                ' || true
              }
            } 2>&1
          ]
        end
        if $? != 0 then
          raise RuntimeError, message
        end
      end

      def undeploy(vimfiles_path)
        deploy_path = make_deploy_path(vimfiles_path)
        if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/
          message = %x[
            del /QF "#{deploy_path}" 2>&1
          ]
        else
          message = %x[
            {
              rm -fr '#{deploy_path}'
            } 2>&1
          ]
        end
        if $? != 0 then
          raise RuntimeError, message
        end
      end

      def list_versions()
        if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/
          tags = %x[
            cd "#{cached_repo_path.tr('/', '\\')}" &
            git tag 2>&1
          ]
        else
          tags = %x[
            {
              cd '#{cached_repo_path}' &&
              git tag
            } 2>&1
          ]
        end
        if $? != 0 then
          raise RuntimeError, message
        end

        tags.
          split(/[\r\n]/).
          select {|t| t != ''}.
          map {|t| Gem::Version.create(t)}
      end

      def update_locked_version()
        @locked_version =
          version_contraint.find_the_best_version(list_versions())
      end
    end

    class FlavorFile
      attr_reader :flavors

      def initialize()
        @flavors = {}
        @default_groups = [:default]
      end

      def interpret(&block)
        instance_eval(&block)
      end

      def eval_flavorfile(flavorfile_path)
        content = File.open(flavorfile_path, 'rb') do |f|
          f.read()
        end
        interpret do
          instance_eval(content)
        end
      end

      def repo_uri_from_repo_name(repo_name)
        proto = ENV['VIM_FLAVOR_PROTOCOL'] or 'git'
        if /^([^\/]+)$/.match(repo_name) then
          m = Regexp.last_match
          "#{proto}://github.com/vim-scripts/#{m[1]}.git"
        elsif /^([A-Za-z0-9_-]+)\/(.*)$/.match(repo_name) then
          m = Regexp.last_match
          "#{proto}://github.com/#{m[1]}/#{m[2]}.git"
        elsif /^[a-z]+:\/\/.*$/.match(repo_name) then
          repo_name
        else
          raise "repo_name is written in invalid format: #{repo_name.inspect}"
        end
      end

      def flavor(repo_name, *args)
        options = Hash === args.last ? args.pop : {}
        options[:groups] ||= []
        version_contraint = VersionConstraint.new(args.last || '>= 0')

        f = Flavor.new()
        f.repo_name = repo_name
        f.repo_uri = repo_uri_from_repo_name(repo_name)
        f.version_contraint = version_contraint
        f.groups = @default_groups + options[:groups]

        @flavors[f.repo_uri] = f
      end

      def group(*group_names, &block)
        @default_groups.concat(group_names)
        yield
      ensure
        group_names.each do
          @default_groups.pop()
        end
      end
    end

    class LockFile
      # TODO: Resolve dependencies recursively.

      attr_reader :flavors, :path

      def initialize(path)
        @flavors = {}  # repo_uri => flavor
        @path = path
      end

      def load()
        h = File.open(@path, 'rb') do |f|
          YAML.load(f.read())
        end

        @flavors = self.class.flavors_from_poro(h[:flavors])
      end

      def save()
        h = {}

        h[:flavors] = self.class.poro_from_flavors(@flavors)

        File.open(@path, 'wb') do |f|
          YAML.dump(h, f)
        end
      end

      def self.poro_from_flavors(flavors)
        Hash[
          flavors.values.map {|f|
            [
              f.repo_uri,
              {
                :groups => f.groups,
                :locked_version => f.locked_version.to_s(),
                :repo_name => f.repo_name,
                :version_contraint => f.version_contraint.to_s(),
              }
            ]
          }
        ]
      end

      def self.flavors_from_poro(poro)
        Hash[
          poro.to_a().map {|repo_uri, h|
            f = Flavor.new()
            f.groups = h[:groups]
            f.locked_version = Gem::Version.create(h[:locked_version])
            f.repo_name = h[:repo_name]
            f.repo_uri = repo_uri
            f.version_contraint = VersionConstraint.new(h[:version_contraint])
            [f.repo_uri, f]
          }
        ]
      end
    end

    class Facade
      attr_reader :flavorfile
      attr_accessor :flavorfile_path
      attr_reader :lockfile
      attr_accessor :lockfile_path
      attr_accessor :traced

      def initialize()
        @flavorfile = nil  # FlavorFile
        @flavorfile_path = "#{Dir.getwd()}/VimFlavor"
        @lockfile = nil  # LockFile
        @lockfile_path = "#{Dir.getwd()}/VimFlavor.lock"
        @traced = false
      end

      def trace(message)
        print(message) if @traced
      end

      def load()
        @flavorfile = FlavorFile.new()
        @flavorfile.eval_flavorfile(@flavorfile_path)

        @lockfile = LockFile.new(@lockfile_path)
        @lockfile.load() if File.exists?(@lockfile_path)
      end

      def make_new_flavors(current_flavors, locked_flavors, mode)
        new_flavors = {}

        current_flavors.each do |repo_uri, cf|
          lf = locked_flavors[repo_uri]
          nf = cf.dup()

          nf.locked_version =
            if (not lf) or
              cf.version_contraint != lf.version_contraint or
              mode == :update then
              cf.locked_version
            else
              lf.locked_version
            end

          new_flavors[repo_uri] = nf
        end

        new_flavors
      end

      def create_vim_script_for_bootstrap(vimfiles_path)
        bootstrap_path = "#{vimfiles_path.to_flavors_path()}/bootstrap.vim"
        FileUtils.mkdir_p(File.dirname(bootstrap_path))
        File.open(bootstrap_path, 'w') do |f|
          f.write(<<-'END')
            function! s:bootstrap()
              let current_rtp = &runtimepath
              let current_rtps = split(current_rtp, ',')
              set runtimepath&
              let default_rtp = &runtimepath
              let default_rtps = split(default_rtp, ',')
              let user_dir = default_rtps[0]
              let user_after_dir = default_rtps[-1]
              let base_rtps =
              \ filter(copy(current_rtps),
              \        'v:val !=# user_dir && v:val !=# user_after_dir')
              let flavor_dirs =
              \ filter(split(glob(user_dir . '/flavors/*'), '\n'),
              \        'isdirectory(v:val)')
              let new_rtps =
              \ []
              \ + [user_dir]
              \ + flavor_dirs
              \ + base_rtps
              \ + map(reverse(copy(flavor_dirs)), 'v:val . "/after"')
              \ + [user_after_dir]
              let &runtimepath = join(new_rtps, ',')
            endfunction

            call s:bootstrap()
          END
        end
      end

      def deploy_flavors(flavor_list, vimfiles_path)
        FileUtils.rm_rf(
          ["#{vimfiles_path.to_flavors_path()}"],
          :secure => true
        )

        create_vim_script_for_bootstrap(vimfiles_path)
        flavor_list.each do |f|
          trace("Deploying #{f.repo_name} (#{f.locked_version})\n")
          f.deploy(vimfiles_path)
        end
      end

      def save_lockfile()
        @lockfile.save()
      end

      def complete_locked_flavors(mode)
        nfs = {}
        @flavorfile.flavors.each do |repo_uri, cf|
          nf = cf.dup()
          lf = @lockfile.flavors[repo_uri]

          trace("Using #{nf.repo_name} ... ")
          begin
            if not File.exists?(nf.cached_repo_path)
              nf.clone()
            end

            if mode == :upgrade_all or
              (not lf) or
              nf.version_contraint != lf.version_contraint then
              nf.fetch()
              nf.update_locked_version()
            else
              nf.locked_version = lf.locked_version
            end
          end
          trace("(#{nf.locked_version})\n")

          nfs[repo_uri] = nf
        end

        @lockfile.instance_eval do
          @flavors = nfs
        end
      end

      def get_default_vimfiles_path()
        # FIXME: Compute more appropriate value.
        if RUBY_PLATFORM.downcase =~ /mswin(?!ce)|mingw|bccwin/
          "#{ENV['HOME']}/vimfiles"
        else
          "#{ENV['HOME']}/.vim"
        end
      end

      def install(vimfiles_path)
        load()
        complete_locked_flavors(:upgrade_if_necessary)
        save_lockfile()
        deploy_flavors(lockfile.flavors.values, vimfiles_path)
      end

      def upgrade(vimfiles_path)
        load()
        complete_locked_flavors(:upgrade_all)
        save_lockfile()
        deploy_flavors(lockfile.flavors.values, vimfiles_path)
      end
    end

    class CLI < Thor
      desc 'install', 'Install Vim plugins according to VimFlavor file.'
      method_option :vimfiles_path,
        :desc => 'A path to your vimfiles directory.'
      def install()
        facade = Facade.new()
        facade.traced = true
        facade.install(
          options[:vimfiles_path] || facade.get_default_vimfiles_path()
        )
      end

      desc 'upgrade', 'Upgrade Vim plugins according to VimFlavor file.'
      method_option :vimfiles_path,
        :desc => 'A path to your vimfiles directory.'
      def upgrade()
        facade = Facade.new()
        facade.traced = true
        facade.upgrade(
          options[:vimfiles_path] || facade.get_default_vimfiles_path()
        )
      end
    end
  end
end
