#!/usr/bin/env ruby

# Bind mounts hierarchy: from => to (relative)
# If 'to' is nil, path will be the same
mounts = { '/nix/store' => nil,
           '/dev' => nil,
           '/proc' => nil,
           '/sys' => nil,
           '/etc' => 'host-etc',
           '/tmp' => 'host-tmp',
           '/home' => nil,
           '/var' => nil,
           '/run' => nil,
           '/root' => nil,
         }

# Propagate environment variables
envvars = [ 'TERM',
            'DISPLAY',
            'HOME',
            'XDG_RUNTIME_DIR',
            'LANG',
            'SSL_CERT_FILE',
          ]

require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'set'
require 'fiddle'

def write_file(path, str)
  File.open(path, 'w') { |file| file.write str }
end

# Import C standard library and several needed calls
$libc = Fiddle.dlopen nil

def make_fcall(name, args, output)
  c = Fiddle::Function.new $libc[name], args, output
  lambda do |*args|
    ret = c.call *args
    raise SystemCallError.new Fiddle.last_error if ret < 0
    return ret
  end
end

$fork = make_fcall 'fork', [], Fiddle::TYPE_INT

CLONE_NEWNS   = 0x00020000
CLONE_NEWUSER = 0x10000000
$unshare = make_fcall 'unshare', [Fiddle::TYPE_INT], Fiddle::TYPE_INT

MS_BIND = 0x1000
MS_REC  = 0x4000
$mount = make_fcall 'mount', [Fiddle::TYPE_VOIDP,
                              Fiddle::TYPE_VOIDP,
                              Fiddle::TYPE_VOIDP,
                              Fiddle::TYPE_LONG,
                              Fiddle::TYPE_VOIDP],
                    Fiddle::TYPE_INT

# Read command line args
abort "Usage: chrootenv swdir program args..." unless ARGV.length >= 2
swdir = Pathname.new ARGV[0]
execp = ARGV.drop 1

# Populate extra mounts
if not ENV["CHROOTENV_EXTRA_BINDS"].nil?
  for extra in ENV["CHROOTENV_EXTRA_BINDS"].split(':')
    paths = extra.split('=')
    if not paths.empty?
      if paths.size <= 2
        mounts[paths[0]] = paths[1]
      else
        $stderr.puts "Ignoring invalid entry in CHROOTENV_EXTRA_BINDS: #{extra}"
      end
    end
  end
end

# Set destination paths for mounts
mounts = mounts.map { |k, v| [k, v.nil? ? k.sub(/^\/*/, '') : v] }.to_h

# Create temporary directory for root and chdir
root = Dir.mktmpdir 'chrootenv'

# Fork process; we need this to do a proper cleanup because
# child process will chroot into temporary directory.
# We use imported 'fork' instead of native to overcome
# CRuby's meddling with threads; this should be safe because
# we don't use threads at all.
$cpid = $fork.call
if $cpid == 0
  # Save user UID and GID
  uid = Process.uid
  gid = Process.gid

  # Create new mount and user namespaces
  # CLONE_NEWUSER requires a program to be non-threaded, hence
  # native fork above.
  $unshare.call CLONE_NEWNS | CLONE_NEWUSER

  # Map users and groups to the parent namespace
  begin
    # setgroups is only available since Linux 3.19
    write_file '/proc/self/setgroups', 'deny'
  rescue
  end
  write_file '/proc/self/uid_map', "#{uid} #{uid} 1"
  write_file '/proc/self/gid_map', "#{gid} #{gid} 1"

  # Do rbind mounts.
  mounts.each do |from, rto|
    to = "#{root}/#{rto}"
    FileUtils.mkdir_p to
    $mount.call from, to, nil, MS_BIND | MS_REC, nil
  end

  # Chroot!
  Dir.chroot root
  Dir.chdir '/'

  # Symlink swdir hierarchy
  mount_dirs = Set.new mounts.map { |_, v| Pathname.new v }
  link_swdir = lambda do |swdir, prefix|
    swdir.find do |path|
      rel = prefix.join path.relative_path_from(swdir)
      # Don't symlink anything in binded or symlinked directories
      Find.prune if mount_dirs.include? rel or rel.symlink?
      if not rel.directory?
        # File does not exist; make a symlink and bail out
        rel.make_symlink path
        Find.prune
      end
      # Recursively follow symlinks
      link_swdir.call path.readlink, rel if path.symlink?
    end
  end
  link_swdir.call swdir, Pathname.new('')

  # New environment
  new_env = Hash[ envvars.map { |x| [x, ENV[x]] } ]

  # Finally, exec!
  exec(new_env, *execp, close_others: true, unsetenv_others: true)
end

# Wait for a child. If we catch a signal, resend it to child and continue
# waiting.
def wait_child
  begin
    Process.wait

    # Return child's exit code
    if $?.exited?
      exit $?.exitstatus
      else
      exit 1
    end
  rescue SignalException => e
    Process.kill e.signo, $cpid
    wait_child
  end
end

begin
  wait_child
ensure
  # Cleanup
  FileUtils.rm_rf root, secure: true
end
