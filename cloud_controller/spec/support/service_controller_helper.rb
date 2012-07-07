# Shim so that we can stub/mock out desired return values for our forked
require 'net/telnet'

class Net::Telnet
  def initialize(opts)
  end

  def close
  end
end

# gateway
class ServiceProvisionerStub
  def provision_service(version, plan)
  end

  def unprovision_service(service_id)
  end

  def bind_instance(service_id, binding_options)
  end

  def unbind_instance(service_id, handle_id, binding_options)
  end
end

def start_gateway(svc, shim)
  svc_info = {
    :name    => svc.name,
    :version => svc.version
  }
  uri = URI.parse(svc.url)
  gateway = VCAP::Services::SynchronousServiceGateway.new(:service => svc_info, :token => svc.token, :provisioner => shim)
  pid = Process.fork do
    # Prevent the subscriptions registered with the rails initializers from running when we fork the server and start it.
    # If we don't do this we run the risk of a) starting NATS if it isn't running, or b) sending messages
    # through an existing NATS server, possibly upsetting already running tests.
    EM.instance_variable_set(:@next_tick_queue, [])

    outfile = File.new('/dev/null', 'w+')
    $stderr.reopen(outfile)
    $stdout.reopen(outfile)
    trap("INT") { exit }
    Thin::Server.start(uri.host, uri.port, gateway, :signals => false)
  end
  server_alive = wait_for {port_open? uri.port}
  server_alive.should be_true

  # In case an exception is thrown before we can cleanup
  at_exit { Process.kill(9, pid) if VCAP.process_running?(pid) }

  pid
end

def stop_gateway(pid)
  Process.kill("INT", pid)
  Process.waitpid(pid)
end

def post_msg(*args, &blk)
  msg = yield
  request.env['RAW_POST_DATA'] = msg.encode
  post(*args)
end

def put_msg(*args, &blk)
  msg = yield
  request.env['RAW_POST_DATA'] = msg.encode
  put(*args)
end

def delete_msg(*args, &blk)
  msg = yield
  request.env['RAW_POST_DATA'] = msg.encode
  delete(*args)
end

def port_open?(port)
  port_open = true
  begin
    s = TCPSocket.new('localhost', port)
    s.close()
  rescue
    port_open = false
  end
  port_open
end

def wait_for(timeout=5, &predicate)
  start = Time.now()
  cond_met = predicate.call()
  while !cond_met && ((Time.new() - start) < timeout)
    cond_met = predicate.call()
    sleep(0.2)
  end
  cond_met
end
