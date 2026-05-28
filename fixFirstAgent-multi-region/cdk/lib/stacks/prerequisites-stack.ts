import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as ssm from 'aws-cdk-lib/aws-ssm';

export interface PrerequisitesStackProps extends cdk.StackProps {
  appName: string;
  /**
   * The domain name for the agent API endpoint.
   * Example: "api.fixfirst.example.com"
   */
  domainName: string;
  /**
   * The parent hosted zone name.
   * Example: "fixfirst.example.com"
   *
   * If you already have a hosted zone, pass its ID via existingHostedZoneId
   * and this will be used only for lookup.
   */
  hostedZoneName: string;
  /**
   * If you already have a Route 53 hosted zone, provide its ID here.
   * If empty/undefined, a new hosted zone will be created.
   */
  existingHostedZoneId?: string;
}

/**
 * Prerequisites Stack
 *
 * Creates (or imports) a Route 53 hosted zone and provisions an ACM certificate
 * with DNS validation for the agent API custom domain.
 *
 * Deploy this stack in EACH region where you need a certificate (ACM certs are regional).
 *
 * After deployment:
 * - If a NEW hosted zone was created, update your domain registrar's NS records
 *   to point to the name servers shown in the stack outputs.
 * - The certificate will auto-validate once DNS is resolvable.
 */
export class PrerequisitesStack extends cdk.Stack {
  public readonly hostedZone: route53.IHostedZone;
  public readonly certificate: acm.ICertificate;

  constructor(scope: Construct, id: string, props: PrerequisitesStackProps) {
    super(scope, id, props);

    const region = cdk.Stack.of(this).region;

    // ─── Hosted Zone ─────────────────────────────────────────────────────

    if (props.existingHostedZoneId) {
      // Import existing hosted zone
      this.hostedZone = route53.HostedZone.fromHostedZoneAttributes(this, 'HostedZone', {
        hostedZoneId: props.existingHostedZoneId,
        zoneName: props.hostedZoneName,
      });
    } else {
      // Create a new hosted zone
      this.hostedZone = new route53.HostedZone(this, 'HostedZone', {
        zoneName: props.hostedZoneName,
        comment: `Hosted zone for ${props.appName} multi-region agent`,
      });

      // Output the NS records — user must add these to their domain registrar
      new cdk.CfnOutput(this, 'NameServers', {
        value: cdk.Fn.join(', ', (this.hostedZone as route53.HostedZone).hostedZoneNameServers!),
        description:
          'Add these NS records to your domain registrar to delegate DNS to this hosted zone',
      });
    }

    // ─── ACM Certificate (DNS validated) ─────────────────────────────────

    this.certificate = new acm.Certificate(this, 'Certificate', {
      domainName: props.domainName,
      validation: acm.CertificateValidation.fromDns(this.hostedZone),
      certificateName: `${props.appName}-multi-region-cert`,
    });

    // ─── SSM Parameters (for other stacks to consume) ────────────────────

    new ssm.StringParameter(this, 'SSM-HostedZoneId', {
      parameterName: `/${props.appName}/multi-region/hosted-zone-id`,
      stringValue: this.hostedZone.hostedZoneId,
      description: 'Route 53 hosted zone ID for multi-region routing',
    });

    new ssm.StringParameter(this, 'SSM-CertificateArn', {
      parameterName: `/${props.appName}/multi-region/certificate-arn`,
      stringValue: this.certificate.certificateArn,
      description: 'ACM certificate ARN for the agent API custom domain',
    });

    // ─── Outputs ─────────────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'HostedZoneId', {
      value: this.hostedZone.hostedZoneId,
      description: 'Route 53 hosted zone ID',
    });

    new cdk.CfnOutput(this, 'CertificateArn', {
      value: this.certificate.certificateArn,
      description: `ACM certificate ARN in ${region}`,
    });
  }
}
