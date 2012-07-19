EM.next_tick do
  NATS.subscribe("cloudcontroller.bulk.credentials.#{AppConfig[:cc_partition]}") do |_, reply|
    NATS.publish(reply, AppConfig[:bulk_api][:auth].to_json)
  end
end
