'use client';

import React, { useState, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import { photosApi } from '@/lib/api/photos';
import { Users, ChevronRight } from 'lucide-react';
import { logger } from '@/lib/logger';

interface Person {
  person_id: string;
  display_name?: string;
  face_count: number;
  thumbnail: string; // Base64 encoded
}

interface FaceFilterProps {
  onFilterByPerson: (personId: string | null) => void;
  selectedPersonId?: string | null;
}

export function FaceFilter({ onFilterByPerson, selectedPersonId }: FaceFilterProps) {
  const [isExpanded, setIsExpanded] = useState(true);
  
  // Fetch faces from API
  const { data: persons, isLoading, error } = useQuery<Person[]>({
    queryKey: ['faces-filtered'], // Use a new key to invalidate old cache
    queryFn: async () => {
      return photosApi.getFaces() as unknown as Person[];
    },
    staleTime: 1000 * 60 * 5, // Cache for 5 minutes
    gcTime: 1000 * 60 * 10, // Keep in cache for 10 minutes
  });
  
  const handlePersonClick = (personId: string) => {
    logger.debug('Face clicked:', personId, 'currently selected:', selectedPersonId);
    if (selectedPersonId === personId) {
      logger.debug('Clearing face filter');
      onFilterByPerson(null); // Clear filter if clicking same person
    } else {
      logger.debug('Setting face filter to:', personId);
      onFilterByPerson(personId);
    }
  };
  
  const handleClearFilter = () => {
    onFilterByPerson(null);
  };
  
  return (
    <div className="mb-6">
      {/* Header */}
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        className="flex items-center justify-between w-full mb-3 text-left"
      >
        <div className="flex items-center space-x-2">
          <Users className="w-4 h-4 text-muted-foreground" />
          <h4 className="text-sm font-medium text-foreground">Faces</h4>
          {selectedPersonId && (
            <span className="bg-primary/10 text-primary text-xs px-2 py-0.5 rounded-full">
              1 selected
            </span>
          )}
        </div>
        <ChevronRight 
          className={`w-4 h-4 text-muted-foreground transform transition-transform ${
            isExpanded ? 'rotate-90' : ''
          }`}
        />
      </button>
      
      {/* Face Grid */}
      {isExpanded && (
        <div className="space-y-3">
          {isLoading && (
            <div className="flex items-center justify-center py-8">
              <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-primary"></div>
            </div>
          )}
          
          {error && (
            <div className="text-sm text-red-600 text-center py-4">
              Failed to load faces
            </div>
          )}
          
          {persons && persons.length === 0 && (
            <div className="text-sm text-muted-foreground text-center py-4">
              No faces detected yet
            </div>
          )}
          
          {persons && persons.length > 0 && (
            <>
              <div className="text-xs text-muted-foreground mb-2">
                {persons.length} faces detected
              </div>
              {/* Face thumbnails grid */}
              <div className="grid grid-cols-4 gap-2 max-h-none overflow-visible">
                {persons.map((person) => (
                  <button
                    key={person.person_id}
                    onClick={() => handlePersonClick(person.person_id)}
                    className={`relative group cursor-pointer rounded-lg overflow-hidden transition-all ${
                      selectedPersonId === person.person_id
                        ? 'ring-2 ring-primary ring-offset-2 ring-offset-background'
                        : 'hover:ring-2 hover:ring-border'
                    }`}
                    title={person.display_name || `Person ${person.person_id.slice(-4)}`}
                  >
                    {/* Face thumbnail */}
                    <div className="aspect-square bg-muted">
                        <img
                          src={photosApi.getFaceThumbnailUrl(person.person_id)}
                          alt={person.display_name || 'Person'}
                          className="w-full h-full object-cover"
                          onError={(e) => {
                            // Show fallback icon if thumbnail fails to load
                          const target = e.target as HTMLImageElement;
                          target.style.display = 'none';
                          const fallback = target.nextElementSibling as HTMLElement;
                          if (fallback) fallback.style.display = 'flex';
                        }}
                      />
                      <div className="w-full h-full flex items-center justify-center" style={{ display: 'none' }}>
                        <Users className="w-6 h-6 text-muted-foreground" />
                      </div>
                    </div>
                    
                    {/* Photo count badge */}
                    <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/60 to-transparent p-1">
                      <span className="text-xs text-white font-medium">
                        {person.face_count}
                      </span>
                    </div>
                    
                    {/* Selection indicator */}
                    {selectedPersonId === person.person_id && (
                      <div className="absolute inset-0 bg-primary/20 pointer-events-none" />
                    )}
                  </button>
                ))}
              </div>
              
              {/* Clear filter button */}
              {selectedPersonId && (
                <button
                  onClick={handleClearFilter}
                  className="w-full text-sm text-primary hover:text-primary/80 py-2 border border-primary/30 rounded-md hover:bg-primary/10 transition-colors"
                >
                  Clear face filter
                </button>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}
