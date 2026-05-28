import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';

export interface RoutingStackProps extends cdk.StackProps {
  appName: string;
  /** The custom domain name (e.g., api.fixfirst.example.com) */
  domainName: string;
  /** Route 53 hosted zone ID */
  hostedZoneId: string;
  /** Route 53 hosted zone name (e.g., fixfirst.example.com) */
  hostedZoneName: string;
  /** Regional domain name of the primary API Gateway custom domain */
  primaryApiDomainName: string;
  /** Hosted zone ID of the primary API Gateway regional endpoint */
  primaryApiHostedZoneId: string;
  /** Regional domain name of the secondary API Gateway custom domain */
  secondaryApiDomainName: string;
  /** Hosted zone ID of the secondary API Gateway regional endpoint */
  secondaryApiHostedZoneId: string;
  /** Primary region identifier */
  primaryRegion: string;
  /** Secondary region identifier */
  secondaryRegion: string;
}

/**
 * Routing Stack
 *
 * Creates Route 53 failover DNS records and a CloudWatch alarm-based health check
 * for operator-controlled failover between the primary and secondary regions.
 *
 * Failover is triggered by publishing a CloudWatch metric:
 *   aws cloudwatch put-metric-data \
 *     --metric-name Failover \
 *     --namespace FixFirstAgent/HealthCheck \
 *     --unit Count --value 1 --region <primary-region>
 *
 * To return to primary:
 *   aws cloudwatch put-metric-data \
 *     --metric-name Failover \
 *     --namespace FixFirstAgent/HealthCheck \
 *     --unit Count --value 0 --region <primary-region>
 */
export class RoutingStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: RoutingStackProps) {
    super(scope, id, props);

    // ─── Hosted Zone Lookup ──────────────────────────────────────────────

    const hostedZone = route53.HostedZone.fromHostedZoneAttributes(this, 'HostedZone', {
      hostedZoneId: props.hostedZoneId,
      zoneName: props.hostedZoneName,
    });

    // ─── CloudWatch Alarm for Operator-Controlled Failover ───────────────
    //
    // The alarm triggers when the "Failover" metric value >= 1.
    // When the alarm is in ALARM state, the Route 53 health check fails,
    // causing DNS to route traffic to the secondary region.

    const failoverAlarm = new cloudwatch.Alarm(this, 'FailoverAlarm', {
      alarmName: `${props.appName}-primary-failover-alarm`,
      alarmDescription:
        'Operator-controlled failover alarm. Publish metric value=1 to trigger failover to secondary region.',
      metric: new cloudwatch.Metric({
        namespace: 'FixFirstAgent/HealthCheck',
        metricName: 'Failover',
        statistic: 'Maximum',
        period: cdk.Duration.seconds(60),
        region: props.primaryRegion,
      }),
      threshold: 1,
      evaluationPeriods: 1,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // ─── Route 53 Health Check (based on CloudWatch alarm) ───────────────

    const healthCheck = new route53.CfnHealthCheck(this, 'PrimaryHealthCheck', {
      healthCheckConfig: {
        type: 'CLOUDWATCH_METRIC',
        alarmIdentifier: {
          name: failoverAlarm.alarmName,
          region: props.primaryRegion,
        },
        insufficientDataHealthStatus: 'Healthy',
      },
      healthCheckTags: [
        { key: 'Name', value: `${props.appName}-primary-health-check` },
      ],
    });

    // ─── Route 53 Failover Records ──────────────────────────────────────

    // Primary failover record — points to primary region API Gateway
    new route53.CfnRecordSet(this, 'PrimaryFailoverRecord', {
      hostedZoneId: props.hostedZoneId,
      name: props.domainName,
      type: 'A',
      setIdentifier: `${props.appName}-primary`,
      failover: 'PRIMARY',
      aliasTarget: {
        dnsName: props.primaryApiDomainName,
        hostedZoneId: props.primaryApiHostedZoneId,
        evaluateTargetHealth: true,
      },
      healthCheckId: healthCheck.attrHealthCheckId,
    });

    // Secondary failover record — points to secondary region API Gateway
    new route53.CfnRecordSet(this, 'SecondaryFailoverRecord', {
      hostedZoneId: props.hostedZoneId,
      name: props.domainName,
      type: 'A',
      setIdentifier: `${props.appName}-secondary`,
      failover: 'SECONDARY',
      aliasTarget: {
        dnsName: props.secondaryApiDomainName,
        hostedZoneId: props.secondaryApiHostedZoneId,
        evaluateTargetHealth: true,
      },
    });

    // ─── Outputs ─────────────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'FailoverAlarmName', {
      value: failoverAlarm.alarmName,
      description: 'CloudWatch alarm name for triggering failover',
    });

    new cdk.CfnOutput(this, 'HealthCheckId', {
      value: healthCheck.attrHealthCheckId,
      description: 'Route 53 health check ID',
    });

    new cdk.CfnOutput(this, 'AgentEndpoint', {
      value: `https://${props.domainName}/invoke`,
      description: 'Multi-region agent invocation endpoint',
    });
  }
}
