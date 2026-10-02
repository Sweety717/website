---
title: "Real-Time Fraud Detection in Java with Kafka Streams and Vector Similarity"
date: "2026-01-01"
description: "How Java, Kafka Streams, and MongoDB vector search combine to catch fraud in real time, from rule-based guardrails to behavioral similarity scoring."
authors:
  - "ricardo-mello"
image: "real-time-fraud-detection-cover.jpg"
categories:
  - "Java"
  - "Kafka"
  - "Mongo"
  - "Machine Learning"
related_posts: []
---

*This content is based on a talk that my colleague Tim Kelly and I presented at [DevNexus 2026](https://devnexus.com/events/real-time-fraud-detection-in-java-with-kafka-streams-vector-similarity) in Atlanta, one of the largest Java conferences in the world.*

Imagine you're at a supermarket or shopping online. You tap your card or click "Buy Now". In that exact moment, your bank has to make a decision: is this transaction legitimate, or is it fraud? And it has to do that in milliseconds, and get it right. If it blocks a real transaction, it frustrates the customer. If it approves a fraudulent one, it leads to financial loss. So the question is: how do banks actually do this? What's happening behind the scenes? In this article, we'll explore a real-world approach to solving this problem using Java, Apache Kafka, Kafka Streams, and vector similarity with MongoDB.

## What We're Building

At a high level, a payment system works like this: a transaction is created, it goes through a validation step, and then a final decision is made to approve or decline.

Now, let's zoom in on that validation step, because this is where fraud detection actually happens. In our approach, this validation is not a single check but a pipeline composed of multiple stages working together:

1. **Guardrails:** Rule-based checks that catch obvious and well-known fraud patterns immediately, like impossible travel or unusual transaction velocity.
2. **Vector Scoring:** AI-powered similarity matching that compares the transaction against known patterns to detect more subtle or behavioral fraud.
3. **Decision:** The final verdict is based on the combined output of both layers: route the transaction to the approved_transactions collection or to the suspicious_transactions collection for further review or definitive blocking.

The decision flow is pretty straightforward. If a transaction is flagged at any point, either by the guardrails or by the vector scoring stage, we treat it as suspicious and store it in the suspicious_transactions collection. From there, it can be reviewed, enriched with more context, or even blocked depending on the scenario. On the other hand, if it passes both layers without any issues, we consider it safe and store it in the approved_transactions collection.

## The Challenge: Millisecond Decisions with Resilience Under Failure

In fraud detection systems, especially in financial applications, speed is not just important, it is critical. Every transaction must be analyzed in real time, often under heavy load, with thousands of events happening every second. At the same time, the system cannot afford to break if a single component fails.

This leads to two non-negotiable constraints:

- Decisions must be made in milliseconds
- The system must remain resilient even when individual components fail

Before we get into how each layer works, it is important to understand how these constraints shape the entire architecture.

A natural first instinct is to build this using a simple synchronous architecture. The payment service calls the fraud service, which then queries the database, and the flow continues to the notification service. This works fine at the beginning. It's simple and easy to understand.

But the problem is that everything is tightly connected. One service depends on the next. Now imagine the database takes a bit longer to respond. That delay starts to affect the whole flow. The fraud service slows down, the payment service has to wait, and the notification service also gets delayed.

At scale, this becomes a real issue. One slow component can impact everything else. So how do we break this dependency and make each service more independent? This is where event-driven architecture comes in.

## The Strategy: Decoupling the System with Event-Driven Architecture

Instead of having services call each other directly, we introduce an event log as the backbone of communication.

[Apache Kafka](https://kafka.apache.org/) allows the payment service to publish a transaction event to a topic, without knowing who will consume it. The fraud service, the notification service, and any other interested component can subscribe to that topic independently.

This fundamentally changes how the system behaves:

- Services are no longer tightly coupled
- Each service can fail or restart without affecting the others
- The system becomes more resilient and easier to scale

At this point, we have removed the direct dependency between services and solved the resilience problem. But we still have another challenge.

## Stateful Checks Without a Database Round-Trip

Many fraud detection techniques depend on understanding recent activity. For example, the system may need to evaluate how a card has been used within a short time window before deciding whether a new transaction is suspicious.

In a traditional architecture, this usually requires querying a database for every transaction. At high throughput, those round-trips add latency that quickly becomes a bottleneck. In a system where decisions must be made in milliseconds, this approach does not scale.

So the question becomes: How do we perform these kinds of checks without hitting the database every time?

### Solving It with Kafka Streams

[Kafka Streams](https://kafka.apache.org/documentation/streams/) is a lightweight Java library that runs inside your application, processing events as they flow through Kafka topics. More importantly, it allows us to maintain state locally.

Instead of querying a remote database for every transaction, we keep the necessary data inside the same process that handles the events, using an embedded store backed by RocksDB.

In our example, we want to analyze transaction activity per card within a short time window. To do that, we group events by card number. Each card number becomes a key, and for each key, the system maintains a running view of recent activity within a defined time window. This means we eliminate network calls and database round-trips from the critical path, relying only on local lookups. For our use case, this makes a big difference.

We avoid unnecessary latency and keep everything fast enough for real-time decisions, without depending on external systems. You can see where this happens directly [in the code](https://github.com/ricardohsmello/fraud-detection-streams-vector/blob/f5496ba6f8a0ad69dbb153e84f19e983f47589ef/src/main/java/com/devnexus/frauddetection/infrastructure/streams/topology/FraudDetectionStreamProcessor.java#L66):

```java
return stream
    .filter((key, tx) -> tx != null)
    .selectKey((key, tx) -> tx.cardNumber())
    .groupByKey(Grouped.with(Serdes.String(), transactionSerde))
    .aggregate(
        FraudDetectionState::empty,
        (cardNumber, newTransaction, currentState) -> { countTransactionsInWindow(); },
        Materialized.as("fraud-detection-store")...
    )
    .toStream()
```

This line is key:

```java
Materialized.as("fraud-detection-store")
```

It tells Kafka Streams to keep the state locally using an embedded store. As new transactions arrive, the state for each card is updated right there in the application, so the system can keep track of recent activity in real time.

At this point, we can evaluate transaction activity in real time without relying on database calls. But that raises an important question: What exactly are we measuring? Which patterns or signals should trigger a fraud decision? This is where guardrails come in.

## Stage 1: Guardrails, Fast Rule-Based Validation

Guardrails are the first layer in our flow. They're just simple checks based on rules, used to catch the most obvious fraud cases as early as possible.

In practice, guardrails can be any business or risk rule that makes sense for your domain. They are fully customizable and evolve over time as new fraud patterns emerge. In our case, we will implement a couple of common examples to illustrate the approach.

**Impossible Travel Check**

[This rule](https://github.com/ricardohsmello/fraud-detection-streams-vector/blob/f5496ba6f8a0ad69dbb153e84f19e983f47589ef/src/main/java/com/devnexus/frauddetection/domain/rules/ImpossibleTravelValidator.java#L20) checks if the same card shows up in places that don't make sense given the time between transactions.

For example, if a card is used in New York and then shows up in São Paulo less than an hour later, that's not realistic. Something is clearly wrong, and we treat that as a strong fraud signal.

```java
public boolean isImpossibleTravelFraud(Transaction previous, Transaction current) {
    double distanceKm = calculateDistanceKm(
        previous.latitude(), previous.longitude(),
        current.latitude(), current.longitude()
    );
    Duration timeBetween = Duration.between(
        previous.transactionTime(),
        current.transactionTime()
    ).abs();
    // block if physically impossible
}
```

**Velocity Check**

[The velocity](https://github.com/ricardohsmello/fraud-detection-streams-vector/blob/f5496ba6f8a0ad69dbb153e84f19e983f47589ef/src/main/java/com/devnexus/frauddetection/domain/rules/VelocityCheckValidator.java#L15) check looks at how many times a card is used in a short period of time. A very common pattern in fraud is when someone tests a stolen card by making several small transactions before trying something bigger.

In our case, if the same card is used more than three times within one minute, we flag it and block the transaction.

```java
public boolean isVelocityFraud(long txCountInWindow, long maxAllowedPerWindow) {
    return txCountInWindow > maxAllowedPerWindow;
}
```

These are just examples. In a real system, guardrails can include a wide range of checks depending on your use case, risk tolerance, and business rules.

## Where Rule-Based Detection Falls Short

Guardrails are fast and effective, but they have blind spots. Consider a transaction like this:

- Amount: $2.00
- City: same as the cardholder's usual city
- Card: same as always
- Activity: nothing unusual on the surface

This transaction would pass every guardrail check. But what if $2 micro-charges at gas stations are a known fraud pattern? This is a classic card-testing technique used before a larger fraudulent purchase. Rules alone cannot catch this, because the system would need to know the pattern in advance. This is where a different approach becomes necessary.

## Stage 2: Vector Scoring, Behavioral Fraud Detection

At this point, the question changes. Instead of asking: "Does this transaction violate a rule?" We ask: "Does this transaction behave like something we have seen before?"

To answer that, we need a way to compare transactions based on behavior, rather than exact values. For example:

- A $12 purchase at a coffee shop
- A $15 purchase at a bakery

These are not identical, but behaviorally they are very similar. On the other hand:

- A $10,000 crypto transaction at 3 AM

This is clearly very different. So how do we represent this idea in a way that a system can understand?

## From Transactions to Vectors

To compare behavior, we need a consistent way to represent a transaction. Instead of working with raw fields such as amount, merchant, or location separately, we transform the entire transaction into a single structured representation. One simple way to think about it is this:

We take a transaction like:

```json
{ "amount": 15.90, "merchant": "Gas Station", "city": "New York" }
```

And turn it into a descriptive text:

```java
String textToEmbed = "merchant=%s, city=%s, amount=%s";
```

This text is then passed to an embedding model, which produces a vector like:
