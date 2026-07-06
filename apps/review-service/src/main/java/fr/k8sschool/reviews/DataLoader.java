package fr.k8sschool.reviews;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * Seeds a few reviews at startup so GET /api/reviews returns data
 * right after the first deployment. Product ids come from the
 * Astronomy Shop catalog (OpenTelemetry demo).
 */
@Component
public class DataLoader implements CommandLineRunner {

    private static final Logger logger = LoggerFactory.getLogger(DataLoader.class);

    private final ReviewRepository repository;

    public DataLoader(ReviewRepository repository) {
        this.repository = repository;
    }

    @Override
    public void run(String... args) {
        if (repository.count() > 0) {
            return;
        }
        repository.saveAll(List.of(
                new Review("OLJCESPC7Z", 5, "The National Park Foundation scope is stunning!",
                        "alice.martin@example.com", "Alice Martin"),
                new Review("OLJCESPC7Z", 4, "Great value for a first telescope.",
                        "bob.dupont@example.com", "Bob Dupont"),
                new Review("66VCHSJNUP", 3, "Tripod is a bit wobbly.",
                        "carole.leroy@example.com", "Carole Leroy"),
                new Review("1YMWWN1N4O", 5, "Perfect eyepiece for planetary viewing.",
                        "david.bernard@example.com", "David Bernard"),
                new Review("L9ECAV7KIM", 4, "Solid build quality, sharp optics.",
                        "emma.petit@example.com", "Emma Petit")
        ));
        logger.info("Seeded {} reviews", repository.count());
    }
}
