module PgHero
  module Methods
    module System
      def system_stats_enabled?
        !system_stats_provider.nil?
      end

      # TODO remove defined checks in 3.0
      def system_stats_provider
        if aws_db_instance_identifier && (defined?(Aws) || defined?(AWS))
          :aws
        elsif gcp_database_id
          :gcp
        elsif azure_resource_id
          :azure
        end
      end

      def cpu_usage(**options)
        system_stats(:cpu, **options)
      end

      def connection_stats(**options)
        system_stats(:connections, **options)
      end

      def replication_lag_stats(**options)
        system_stats(:replication_lag, **options)
      end

      def read_iops_stats(**options)
        system_stats(:read_iops, **options)
      end

      def write_iops_stats(**options)
        system_stats(:write_iops, **options)
      end

      def free_space_stats(**options)
        system_stats(:free_space, **options)
      end

      def rds_stats(metric_name, duration: nil, period: nil, offset: nil, series: false)
        if system_stats_enabled?
          aws_options = {region: region}
          if access_key_id
            aws_options[:access_key_id] = access_key_id
            aws_options[:secret_access_key] = secret_access_key
          end

          client =
            if defined?(Aws)
              Aws::CloudWatch::Client.new(aws_options)
            else
              AWS::CloudWatch.new(aws_options).client
            end

          duration = (duration || 1.hour).to_i
          period = (period || 1.minute).to_i
          offset = (offset || 0).to_i
          end_time = Time.at(((Time.now - offset).to_f / period).ceil * period)
          start_time = end_time - duration

          resp = client.get_metric_statistics(
            namespace: "AWS/RDS",
            metric_name: metric_name,
            dimensions: [{name: "DBInstanceIdentifier", value: aws_db_instance_identifier}],
            start_time: start_time.iso8601,
            end_time: end_time.iso8601,
            period: period,
            statistics: ["Average"]
          )
          data = {}
          resp[:datapoints].sort_by { |d| d[:timestamp] }.each do |d|
            data[d[:timestamp]] = d[:average]
          end

          add_missing_data(data, start_time, end_time, period) if series

          data
        else
          raise NotEnabled, "System stats not enabled"
        end
      end

      def azure_stats(metric_name, duration: nil, period: nil, offset: nil, series: false)
        # TODO DRY with RDS stats
        duration = (duration || 1.hour).to_i
        period = (period || 1.minute).to_i
        offset = (offset || 0).to_i
        end_time = Time.at(((Time.now - offset).to_f / period).ceil * period)
        start_time = end_time - duration

        interval =
          case period
          when 60
            "PT1M"
          when 300
            "PT5M"
          when 900
            "PT15M"
          when 1800
            "PT30M"
          when 3600
            "PT1H"
          else
            raise Error, "Unsupported period"
          end

        client = Azure::Monitor::Profiles::Latest::Mgmt::Client.new
        timespan = "#{start_time.iso8601}/#{end_time.iso8601}"
        results = client.metrics.list(
          azure_resource_id,
          metricnames: metric_name,
          aggregation: "Average",
          timespan: timespan,
          interval: interval
        )

        data = {}
        result = results.value.first
        if result
          result.timeseries.first.data.each do |point|
            data[point.time_stamp.to_time] = point.average
          end
        end

        add_missing_data(data, start_time, end_time, period) if series

        data
      end

      private

      def gcp_stats(metric_name, duration: nil, period: nil, offset: nil, series: false)
        require "google/cloud/monitoring"

        # TODO DRY with RDS stats
        duration = (duration || 1.hour).to_i
        period = (period || 1.minute).to_i
        offset = (offset || 0).to_i
        end_time = Time.at(((Time.now - offset).to_f / period).ceil * period)
        start_time = end_time - duration

        client = Google::Cloud::Monitoring::Metric.new

        interval = Google::Monitoring::V3::TimeInterval.new
        interval.end_time = Google::Protobuf::Timestamp.new(seconds: end_time.to_i)
        # subtract period to make sure we get first data point
        interval.start_time = Google::Protobuf::Timestamp.new(seconds: (start_time - period).to_i)

        aggregation = Google::Monitoring::V3::Aggregation.new
        # may be better to use ALIGN_NEXT_OLDER for space stats to show most recent data point
        # stick with average for now to match AWS
        aggregation.per_series_aligner = Google::Monitoring::V3::Aggregation::Aligner::ALIGN_MEAN
        aggregation.alignment_period = period

        # validate input since we need to interpolate below
        raise Error, "Invalid metric name" unless metric_name =~ /\A[a-z\/_]+\z/i
        raise Error, "Invalid database id" unless gcp_database_id =~ /\A[a-z\-:]+\z/i

        results = client.list_time_series(
          "projects/#{gcp_database_id.split(":").first}",
          "metric.type = \"cloudsql.googleapis.com/database/#{metric_name}\" AND resource.label.database_id = \"#{gcp_database_id}\"",
          interval,
          Google::Monitoring::V3::ListTimeSeriesRequest::TimeSeriesView::FULL,
          aggregation: aggregation
        )

        data = {}
        result = results.first
        if result
          result.points.each do |point|
            time = Time.at(point.interval.start_time.seconds)
            value = point.value.double_value
            value *= 100 if metric_name == "cpu/utilization"
            data[time] = value
          end
        end

        add_missing_data(data, start_time, end_time, period) if series

        data
      end

      def system_stats(metric_key, **options)
        case system_stats_provider
        when :aws
          metrics = {
            cpu: "CPUUtilization",
            connections: "DatabaseConnections",
            replication_lag: "ReplicaLag",
            read_iops: "ReadIOPS",
            write_iops: "WriteIOPS",
            free_space: "FreeStorageSpace"
          }
          rds_stats(metrics[metric_key], **options)
        when :gcp
          if metric_key == :free_space
            quota = gcp_stats("disk/quota", **options)
            used = gcp_stats("disk/bytes_used", **options)
            free_space(quota, used)
          else
            metrics = {
              cpu: "cpu/utilization",
              connections: "postgresql/num_backends",
              replication_lag: "replication/replica_lag",
              read_iops: "disk/read_ops_count",
              write_iops: "disk/write_ops_count"
            }
            gcp_stats(metrics[metric_key], **options)
          end
        when :azure
          if metric_key == :free_space
            quota = azure_stats("storage_limit", **options)
            used = azure_stats("storage_used", **options)
            free_space(quota, used)
          else
            # no read_iops, write_iops
            # could add io_consumption_percent
            metrics = {
              cpu: "cpu_percent",
              connections: "active_connections",
              replication_lag: "pg_replica_log_delay_in_seconds"
            }
            raise Error, "Metric not supported" unless metrics[metric_key]
            azure_stats(metrics[metric_key], **options)
          end
        else
          raise NotEnabled, "System stats not enabled"
        end
      end

      # only use data points included in both series
      # this also eliminates need to align Time.now
      def free_space(quota, used)
        data = {}
        quota.each do |k, v|
          data[k] = v - used[k] if v && used[k]
        end
        data
      end

      def add_missing_data(data, start_time, end_time, period)
        time = start_time
        end_time = end_time
        while time < end_time
          data[time] ||= nil
          time += period
        end
      end
    end
  end
end
