package fr.k8sschool.reviews;

import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

/**
 * A product review left by a customer of the Astronomy Shop.
 *
 * NOTE: userEmail and userName are personal data (PII). They are here on
 * purpose: the "Security & compliance" module of the training (Lab 8) uses
 * them to demonstrate PII leaking into telemetry and how to mask it.
 */
@Entity
@Table(name = "reviews")
public class Review {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    private String productId;
    private int rating;
    private String comment;
    private String userEmail;
    private String userName;
    private Instant createdAt = Instant.now();

    public Review() {
    }

    public Review(String productId, int rating, String comment, String userEmail, String userName) {
        this.productId = productId;
        this.rating = rating;
        this.comment = comment;
        this.userEmail = userEmail;
        this.userName = userName;
    }

    public Long getId() {
        return id;
    }

    public String getProductId() {
        return productId;
    }

    public void setProductId(String productId) {
        this.productId = productId;
    }

    public int getRating() {
        return rating;
    }

    public void setRating(int rating) {
        this.rating = rating;
    }

    public String getComment() {
        return comment;
    }

    public void setComment(String comment) {
        this.comment = comment;
    }

    public String getUserEmail() {
        return userEmail;
    }

    public void setUserEmail(String userEmail) {
        this.userEmail = userEmail;
    }

    public String getUserName() {
        return userName;
    }

    public void setUserName(String userName) {
        this.userName = userName;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(Instant createdAt) {
        this.createdAt = createdAt;
    }
}
