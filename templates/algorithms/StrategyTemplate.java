import java.util.List;
import java.util.Map;

/**
 * Java 17+ starter, with no third-party dependencies.
 * Copy/rename the file AND public class; give your strategy a unique ID.
 * The app still needs a Java execution adapter before it can run this file.
 */
public final class StrategyTemplate {
    public static final String ID = "template_sma";
    public static final String NAME = "Template: SMA distance";
    public static final String DESCRIPTION =
        "Buy above a moving average; exit below it. Long positions only.";
    public static final int INTERVAL_MINUTES = 1;
    public static final int WARMUP_BARS = 200;

    // Expose every number you want evolution to change here.
    // Fractions: 0.005 = 0.5%, 0.02 = 2%.
    public record Parameter(String name, String label, String unit,
                            double defaultValue, double minimum, double maximum) {}

    public static final List<Parameter> PARAMETERS = List.of(
        new Parameter("lookback", "Moving average lookback", "bars", 20, 2, 200),
        new Parameter("entryThreshold", "Distance above average to enter",
                      "fraction", 0.005, 0, 0.1),
        new Parameter("stopFraction", "Protective stop distance",
                      "fraction", 0.02, 0.001, 0.1)
    );

    // closes: completed candles for ONE symbol, oldest to newest.
    // A future adapter can extend Context with OHLCV/watchlist/session data.
    public record Context(List<Double> closes, boolean hasPosition,
                          String positionSide, Map<String, Double> parameters) {
        public Context {
            closes = List.copyOf(closes);
            parameters = Map.copyOf(parameters);
        }
    }

    // action: buy/sell/wait; positionEffect: open/close/null.
    // A signal requests simulator handling; it does not execute an order.
    public record Signal(String action, String reason, String side,
                         String positionEffect, Double stop,
                         Map<String, Double> measurements) {}

    public static Signal evaluate(Context context) {
        int lookback = (int) Math.round(parameter(context, "lookback"));
        double entryThreshold = parameter(context, "entryThreshold");
        double stopFraction = parameter(context, "stopFraction");

        if (context.closes().size() < lookback) {
            return waitFor("Waiting for closed bars.");
        }
        if (context.hasPosition() && !"long".equals(context.positionSide())) {
            return waitFor("This template manages long positions only.");
        }

        // Keep evaluation independent for every portfolio and tuning candidate.
        // Use only the completed candles supplied in Context.
        List<Double> closes = context.closes();
        double total = 0;
        for (int index = closes.size() - lookback; index < closes.size(); index++) {
            double price = closes.get(index);
            if (!Double.isFinite(price) || price <= 0) {
                return waitFor("Invalid closing price.");
            }
            total += price;
        }
        double average = total / lookback;
        if (!Double.isFinite(average) || average <= 0) {
            return waitFor("Invalid moving average.");
        }
        double close = closes.get(closes.size() - 1);
        double distance = close / average - 1;
        Map<String, Double> measurements = Map.of(
            "average", average, "distance", distance
        );

        // EDIT YOUR DECISION LOGIC HERE.
        if (context.hasPosition() && distance < 0) {
            return new Signal("sell", "Close fell below the moving average.",
                              "long", "close", null, measurements);
        }
        if (!context.hasPosition() && distance > entryThreshold) {
            return new Signal("buy",
                "Close is above the moving average by the entry threshold.",
                "long", "open", close * (1 - stopFraction), measurements);
        }
        return new Signal("wait", "No entry or exit condition matched.",
                          "long", null, null, measurements);
    }

    private static Signal waitFor(String reason) {
        return new Signal("wait", reason, "long", null, null, Map.of());
    }

    private static double parameter(Context context, String name) {
        Parameter definition = PARAMETERS.stream()
            .filter(item -> item.name().equals(name)).findFirst().orElseThrow();
        double value = context.parameters().getOrDefault(name, definition.defaultValue());
        return Double.isFinite(value)
            ? Math.max(definition.minimum(), Math.min(definition.maximum(), value))
            : definition.defaultValue();
    }

    // Run this file directly in IntelliJ, or use: java StrategyTemplate.java
    public static void main(String[] args) {
        Context example = new Context(
            List.of(100.0, 100.0, 100.0, 104.0), false, "long",
            Map.of("lookback", 4.0)
        );
        System.out.println(evaluate(example));
    }
}
