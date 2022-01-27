@namespaceAccessible
public class OneGraphWebhookV1 implements Queueable, Database.AllowsCallouts {
  private String deliveryId;
  @TestVisible
  private static String transactionIdStatic;
  private String transactionId;
  private String content;
  private String sobjectName;
  private String triggerType;
  private Integer attempts = 0;
  private Integer maxAttempts = 3;
  private Integer cpuTime = 0;
  // Will be set to true if we know we will exceed
  // execution limits on transaction if we continue
  @TestVisible
  private static Boolean isFinalExecution = false;
  public Boolean shouldExecute = true;
  private static String webhookErrorMessage = 'Error from OneGraph';
  @TestVisible
  private static Boolean sendCalloutDuringTest = false;
  private Boolean isFirstRun = true;

  @TestVisible
  private static Void writeBool(
    JSONGenerator gen,
    String fieldName,
    Boolean b
  ) {
    if (b != null) {
      gen.writeBooleanField(fieldName, b);
    } else {
      gen.writeNullField(fieldName);
    }
  }

  @TestVisible
  private static Void writeObject(
    JSONGenerator gen,
    String fieldName,
    Object o
  ) {
    if (o != null) {
      gen.writeObjectField(fieldName, o);
    } else {
      gen.writeNullField(fieldName);
    }
  }

  @TestVisible
  private static Void writeInt(JSONGenerator gen, String fieldName, Integer i) {
    if (i != null) {
      gen.writeNumberField(fieldName, i);
    } else {
      gen.writeNullField(fieldName);
    }
  }

  @TestVisible
  private static Void writeString(
    JSONGenerator gen,
    String fieldName,
    String s
  ) {
    if (s != null) {
      gen.writeStringField(fieldName, s);
    } else {
      gen.writeNullField(fieldName);
    }
  }

  @TestVisible
  private static String getTriggerType(System.TriggerOperation o) {
    switch on o {
      when AFTER_INSERT {
        return 'insert';
      }
      when AFTER_UPDATE {
        return 'update';
      }
      when AFTER_DELETE {
        return 'delete';
      }
      when AFTER_UNDELETE {
        return 'undelete';
      }
      when else {
        return null;
      }
    }
  }

  @TestVisible
  private static String getJsonContent(
    List<Object> n,
    List<Object> o,
    Integer size,
    String sobjectName,
    String triggerType
  ) {
    JSONGenerator gen = JSON.createGenerator(false); // true -> pretty
    gen.writeStartObject();
    writeInt(gen, 'size', size);
    writeString(gen, 'userId', UserInfo.getUserId());
    writeString(gen, 'sobjectName', sobjectName);
    writeString(gen, 'trigger', triggerType);
    writeBool(gen, 'mayHaveUnsentPayloads', OneGraphWebhookV1.isFinalExecution);
    writeObject(gen, 'new', n);
    writeObject(gen, 'old', o);
    gen.writeEndObject();
    gen.close();
    return gen.getAsString();
  }

  private Boolean hasJobs() {
    return (Limits.getLimitQueueableJobs() - Limits.getQueueableJobs()) > 0;
  }

  @namespaceAccessible
  public OneGraphWebhookV1(string sobjectName, System.TriggerOperation op) {
    Integer startCpu = Limits.getCpuTime();
    this.triggerType = getTriggerType(op);
    this.sobjectName = sobjectName;
    if (OneGraphWebhookV1.isFinalExecution) {
      System.debug(
        LoggingLevel.WARN,
        'Too many jobs queueud for this transaction, refusing to enqueue another.'
      );
      this.shouldExecute = false;
    } else if (!hasJobs()) {
      System.debug(
        LoggingLevel.ERROR,
        'Too many jobs queueud for this transaction, refusing to enqueue another. sobjectName=' +
        sobjectName +
        ', triggerType=' +
        triggerType
      );
      this.shouldExecute = false;
    } else {
      Integer jobsMax = Limits.getLimitQueueableJobs();
      Integer jobsCreated = Limits.getQueueableJobs();
      if (jobsCreated > jobsMax / 2) {
        System.debug(
          LoggingLevel.WARN,
          'Already using half the available jobs, this will be the last job we enqueue for the transaction.'
        );
        OneGraphWebhookV1.isFinalExecution = true;
      }
    }
    if (
      !OneGraphToggleSettings.shouldExecuteForTrigger(
        sobjectName,
        triggerType,
        UserInfo.getUserId()
      )
    ) {
      System.debug(
        LoggingLevel.DEBUG,
        'Skipping execution for trigger via custom setting.'
      );
      this.shouldExecute = false;
    }
    if (this.shouldExecute) {
      this.deliveryId = EncodingUtil.ConvertTohex(Crypto.GenerateAESKey(128));
      if (OneGraphWebhookV1.transactionIdStatic != null) {
        this.isFirstRun = false;
      } else {
        OneGraphWebhookV1.transactionIdStatic = EncodingUtil.ConvertTohex(
          Crypto.GenerateAESKey(128)
        );
      }
      this.transactionId = OneGraphWebhookV1.transactionIdStatic;

      this.content = getJsonContent(
        Trigger.new,
        Trigger.old,
        Trigger.size,
        sobjectName,
        triggerType
      );
    }
    this.cpuTime = Limits.getCpuTime() - startCpu;
  }

  private Boolean isCalloutEnabled() {
    if (Test.isRunningTest() && !sendCalloutDuringTest) {
      return false;
    } else {
      return true;
    }
  }

  private void sendCallout() {
    Integer startCpu = Limits.getCpuTime();
    String orgId = UserInfo.getOrganizationId();
    Long timestamp = DateTime.now().getTime();

    String signature = SigningKey.getSignature(timestamp, content);
    Http h = new Http();
    HttpRequest req = new HttpRequest();
    req.setCompressed(true);
    req.setEndpoint('callout:OneGraph__Callout/webhooks/salesforce');
    req.setMethod('POST');
    req.setHeader('Content-Type', 'application/json');
    req.setHeader('x-salesforce-organization-id', orgId);
    req.setHeader('x-salesforce-sobject-name', sobjectName);
    req.setHeader('x-salesforce-trigger', triggerType);
    req.setHeader('x-salesforce-delivery-id', deliveryId);
    req.setHeader('x-salesforce-transaction-id', transactionId);
    req.setHeader('x-salesforce-first-run', isFirstRun ? 'true' : 'false');
    req.setHeader('x-salesforce-signature', signature);
    req.setBody(content);
    this.cpuTime = this.cpuTime + (Limits.getCpuTime() - startCpu);
    req.setHeader('x-salesforce-cpu-time', String.valueOf(this.cpuTime));
    HTTPResponse res = h.send(req);
    if (res.getStatusCode() != 200) {
      System.debug(
        LoggingLevel.ERROR,
        String.format(
          'Error sending webhook to OneGraph, url={0}, statusCode={1}, statusMessage={2}',
          new List<Object>{
            '/webhooks/salesforce',
            res.getStatusCode(),
            res.getStatus()
          }
        )
      );
      CalloutException e = new CalloutException();
      e.setMessage(webhookErrorMessage);
      throw e;
    }
  }

  private void sendCalloutWithRetries() {
    try {
      attempts = attempts + 1;
      if (isCalloutEnabled()) {
        sendCallout();
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        'Retrying on exception ' + e.getMessage()
      );
      if (attempts >= maxAttempts) {
        System.debug(LoggingLevel.ERROR, 'Too many attempts. Giving up.');
      } else {
        // If it was an error from OneGraph, just make the http request again,
        // otherwise we should requeue a job in case the error is callback after dml
        if (e.getMessage() == webhookErrorMessage) {
          sendCalloutWithRetries();
        } else if (hasJobs()) {
          System.enqueueJob(this);
        } else {
          System.debug(
            LoggingLevel.ERROR,
            'No more queued jobs available. Giving up.'
          );
        }
      }
    }
  }

  @namespaceAccessible
  public void run() {
    Integer startCpu = Limits.getCpuTime();
    if (this.shouldExecute) {
      System.enqueueJob(this);
    }
    this.cpuTime = this.cpuTime + Limits.getCpuTime() - startCpu;
  }

  @namespaceAccessible
  public void execute(QueueableContext context) {
    sendCalloutWithRetries();
  }
}